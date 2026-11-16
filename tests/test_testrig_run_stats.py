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

"""Socket-only tests of transparent TestRIG comparison accounting."""

import importlib
import socket
import threading

import pytest

testrig = importlib.import_module("test_testrig")
wire = testrig.rvfi_dii
stats = importlib.import_module("testrig.run_stats")


@pytest.mark.parametrize("version", (1, 2))
@pytest.mark.parametrize("valid", (False, True))
@pytest.mark.parametrize("requested,received", ((0, 0), (2, 0), (2, 1), (2, 2), (2, 3)))
def test_wire_counts(version: int, valid: bool, requested: int, received: int) -> None:
    """Negotiation is excluded, replies are counted, and bytes are preserved."""
    listener = socket.create_server(("127.0.0.1", 0))
    listener.settimeout(3)
    requests: list[bytes] = []
    errors: list[Exception] = []
    records = [
        wire.RvfiRecord(insn=0x3023, order=i, mem_addr=0x80000000, mem_wmask=0xFF)
        for i in range(received)
    ]
    records.append(wire.RvfiRecord.halt_token())
    encode = wire.RvfiRecord.encode_v1 if version == 1 else wire.RvfiRecord.encode_v2
    packets = [encode(r) for r in records]
    if version == 2 and not valid:
        packets = [raw[:37] + b"\x00" + raw[38:] for raw in packets]
    response = b"".join(packets)

    def serve() -> None:
        try:
            with listener.accept()[0] as peer:
                peer.settimeout(3)
                reader = wire.PacketReader(peer)
                requests.append(reader.read(8))
                peer.sendall(wire.version_query_response())
                requests.append(reader.read(8))
                peer.sendall(wire.version_ack(version))
                for _ in range(requested + 1):
                    requests.append(reader.read(8))
                # Split headers and extension blocks across arbitrary TCP reads.
                for offset in range(0, len(response), 17):
                    peer.sendall(response[offset : offset + 17])
                assert peer.recv(1) == b""
        except Exception as error:
            errors.append(error)

    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    monitor = stats.TraceMonitor("peer", listener.getsockname()[1], 3)
    sent = [
        wire.DiiPacket(wire.VERSION_QUERY_WORD, 0, wire.CMD_END_OF_TRACE).encode(),
        wire.DiiPacket(version, 0, wire.CMD_SET_VERSION).encode(),
        *[wire.DiiPacket(0x13, 0, wire.CMD_INSTRUCTION).encode()] * requested,
        wire.DiiPacket(0, 0, wire.CMD_END_OF_TRACE).encode(),
    ]
    try:
        with socket.create_connection(("127.0.0.1", monitor.port), timeout=3) as engine:
            reader = wire.PacketReader(engine)
            engine.sendall(sent[0])
            assert reader.read(88) == wire.version_query_response()
            engine.sendall(sent[1])
            assert reader.read(16) == wire.version_ack(version)
            engine.sendall(b"".join(sent[2:]))
            assert reader.read(len(response)) == response
        worker.join(timeout=3)
        assert not worker.is_alive()
    finally:
        monitor.close()
        listener.close()
        worker.join(timeout=3)
    assert not errors
    assert not monitor.errors
    assert monitor.traces == [
        stats.TraceCounts(requested, received if version == 1 or valid else 0)
    ]
    assert requests == sent


def test_unconnected_monitor_closes() -> None:
    """Preflight or engine startup failures release reserved ports and threads."""
    monitor = stats.TraceMonitor("peer", 1, 0.1)
    monitor.close()
    monitor.close()
    assert not monitor._thread.is_alive()
    assert not monitor.errors


@pytest.mark.parametrize("version", (1, 2))
def test_truncated_reply(version: int) -> None:
    """A peer closing before its halt token is an accounting error."""
    listener = socket.create_server(("127.0.0.1", 0))
    listener.settimeout(3)

    def serve() -> None:
        with listener.accept()[0] as peer:
            peer.settimeout(3)
            reader = wire.PacketReader(peer)
            reader.read(8)
            peer.sendall(wire.version_ack(version))
            reader.read(16)
            peer.sendall(b"short")

    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    monitor = stats.TraceMonitor("peer", listener.getsockname()[1], 3)
    try:
        with socket.create_connection(("127.0.0.1", monitor.port), timeout=3) as engine:
            reader = wire.PacketReader(engine)
            engine.sendall(wire.DiiPacket(version, 0, wire.CMD_SET_VERSION).encode())
            assert reader.read(16) == wire.version_ack(version)
            engine.sendall(
                wire.DiiPacket(0x13, 0, wire.CMD_INSTRUCTION).encode()
                + wire.DiiPacket(0, 0, wire.CMD_END_OF_TRACE).encode()
            )
            worker.join(timeout=3)
            assert not worker.is_alive()
            assert engine.recv(1) == b""
        monitor._thread.join(timeout=3)
        assert monitor.errors
    finally:
        monitor.close()
        listener.close()
