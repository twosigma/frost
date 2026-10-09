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

"""Test resources/serial_bridge.py over pseudo-terminals, without serial hardware.

Run from the repository root:
./scripts/frost.py run pytest tools/vscode-frost/test/test_serial_bridge.py
"""

import base64
import errno
import importlib.util
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import termios
import time

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "resources" / "serial_bridge.py"
SPEC = importlib.util.spec_from_file_location("frost_serial_bridge", SCRIPT)
assert SPEC and SPEC.loader
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


class Client:
    """Subprocess client with bounded NDJSON reads for PTY tests."""

    def __init__(self, port, *args):
        """Run the packaged serial_bridge.py on `port` with extra `args`."""
        self.process = subprocess.Popen(
            [sys.executable, str(SCRIPT), "--port", str(port), *args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.received = bytearray()

    def send(self, value):
        """Send one complete JSON command."""
        self.process.stdin.write(json.dumps(value).encode() + b"\n")
        self.process.stdin.flush()

    def event(self, timeout=4):
        """Read one event, preserving additional buffered events."""
        deadline = time.monotonic() + timeout
        while b"\n" not in self.received:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "serial helper did not emit its event"
            assert select.select([self.process.stdout], [], [], remaining)[0]
            data = os.read(self.process.stdout.fileno(), 65536)
            assert data, self.process.stderr.read().decode()
            self.received.extend(data)
        line, _, self.received = self.received.partition(b"\n")
        return json.loads(line)

    def close(self):
        """Reap only this fixture process and close its protocol pipes."""
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=3)
        for stream in [self.process.stdin, self.process.stdout, self.process.stderr]:
            if not stream.closed:
                stream.close()


@pytest.fixture
def uart():
    """Yield (master fd, device path, start) for a new PTY; stop every helper after."""
    master, slave = os.openpty()
    path = Path(os.ttyname(slave))
    os.close(slave)
    clients = []

    def start(*args):
        client = Client(path, *args)
        clients.append(client)
        return client

    yield master, path, start
    for client in clients:
        client.close()
    try:
        os.close(master)
    except OSError as error:
        assert error.errno == errno.EBADF


def read_bytes(fd, length):
    """Read an exact byte count from a PTY with a deadline."""
    data = bytearray()
    deadline = time.monotonic() + 4
    while len(data) < length:
        remaining = deadline - time.monotonic()
        assert remaining > 0
        assert select.select([fd], [], [], remaining)[0]
        data.extend(os.read(fd, length - len(data)))
    return bytes(data)


def test_raw_binary_bidirectional_and_fragmented_commands(uart):
    """Relay all byte values both ways and accept a command split across pipe writes.

    The port must be left in raw mode at the requested baud.
    """
    master, path, start = uart
    client = start("--baud", "230400")
    assert client.event() == {"type": "ready", "port": str(path), "baud": 230400}
    payload = bytes(range(256)) + "split UTF-8: Δ🙂".encode()
    os.write(master, payload[:257])
    os.write(master, payload[257:])
    received = bytearray()
    while len(received) < len(payload):
        event = client.event()
        assert event["type"] == "data"
        received.extend(base64.b64decode(event["data"], validate=True))
    assert received == payload
    command = (
        json.dumps(
            {"type": "write", "data": base64.b64encode(payload).decode()}
        ).encode()
        + b"\n"
    )
    client.process.stdin.write(command[:17])
    client.process.stdin.flush()
    client.process.stdin.write(command[17:])
    client.process.stdin.flush()
    assert read_bytes(master, len(payload)) == payload
    attrs = termios.tcgetattr(master)
    assert attrs[0] == attrs[1] == attrs[3] == 0
    assert attrs[4] == attrs[5] == termios.B230400


@pytest.mark.parametrize("finish", ["close", "eof", "term"])
def test_close_eof_and_host_termination_release_owned_fd(uart, finish):
    """Exit 0 and release the port on a close command, stdin EOF, or SIGTERM."""
    _, path, start = uart
    client = start()
    assert client.event()["type"] == "ready"
    if finish == "close":
        client.send({"type": "close"})
        assert client.event()["type"] == "closed"
    elif finish == "eof":
        client.process.stdin.close()
        assert client.event()["type"] == "closed"
    else:
        client.process.send_signal(signal.SIGTERM)
    assert client.process.wait(timeout=3) == 0
    reopened = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    os.close(reopened)


def test_external_reader_is_refused_without_termios_changes(uart):
    """Refuse a port that another process holds, and name that process's PID.

    The other reader's termios settings must stay unchanged.
    """
    _, path, start = uart
    external = os.open(path, os.O_RDWR | os.O_NOCTTY)
    try:
        before = termios.tcgetattr(external)
        client = start("--baud", "9600")
        error = client.event()
        assert error["type"] == "error"
        assert str(os.getpid()) in error["message"]
        assert "left untouched" in error["message"]
        assert client.process.wait(timeout=3) == 1
        assert termios.tcgetattr(external) == before
        os.fstat(external)
    finally:
        os.close(external)


def test_device_alias_does_not_bypass_an_external_reader(uart, tmp_path):
    """Detect another reader when the port is opened through a symlink."""
    _, path, _ = uart
    alias = tmp_path / "serial-alias"
    alias.symlink_to(path)
    external = os.open(path, os.O_RDWR | os.O_NOCTTY)
    client = Client(alias)
    try:
        before = termios.tcgetattr(external)
        assert "already open" in client.event()["message"]
        assert client.process.wait(timeout=3) == 1
        assert termios.tcgetattr(external) == before
    finally:
        client.close()
        os.close(external)


def test_disconnected_device_reports_error_and_exits(uart):
    """Report an error, then closed, and exit 1 when the device goes away."""
    master, _, start = uart
    client = start()
    assert client.event()["type"] == "ready"
    os.close(master)
    assert client.event()["type"] == "error"
    assert client.event()["type"] == "closed"
    assert client.process.wait(timeout=3) == 1


def test_second_bridge_cannot_adopt_first_descriptor(uart):
    """Refuse a second helper, or any plain open, on a port the first one holds.

    The first helper keeps its termios settings and keeps receiving data.
    """
    master, path, start = uart
    first = start()
    assert first.event()["type"] == "ready"
    with pytest.raises(OSError) as denied:
        os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    assert denied.value.errno == errno.EBUSY
    before = termios.tcgetattr(master)
    second = start("--baud", "9600")
    assert second.event()["type"] == "error"
    assert second.process.wait(timeout=3) == 1
    assert first.process.poll() is None
    assert termios.tcgetattr(master) == before
    os.write(master, b"owner still receives")
    assert base64.b64decode(first.event()["data"]) == b"owner still receives"


def test_opener_race_is_detected_before_changing_termios(uart, monkeypatch):
    """Catch a reader that opens the port after the first /proc check.

    The recheck after locking must refuse the port before termios changes.
    """
    master, path, _ = uart
    before = termios.tcgetattr(master)
    original = bridge.require_unused
    other = None
    calls = 0

    def racing_check(device, own_fd=None):
        nonlocal other, calls
        original(device, own_fd)
        calls += 1
        if calls == 1:
            other = os.open(path, os.O_RDWR | os.O_NOCTTY)

    monkeypatch.setattr(bridge, "require_unused", racing_check)
    try:
        with pytest.raises(bridge.BridgeError, match="already open"):
            bridge.open_owned(path, 9600)
        assert termios.tcgetattr(master) == before
        os.fstat(other)
    finally:
        if other is not None:
            os.close(other)


def test_reconfigure_restores_baud_without_flushing_received_bytes(uart):
    """Reapply the configured baud on reconfigure without dropping received bytes."""
    master, _, start = uart
    client = start()
    assert client.event()["type"] == "ready"
    attrs = termios.tcgetattr(master)
    attrs[4] = attrs[5] = termios.B9600
    termios.tcsetattr(master, termios.TCSANOW, attrs)
    payload = b"buffered before reconfigure\x00\xff"
    os.write(master, payload)
    client.send({"type": "reconfigure"})
    received = bytearray()
    reconfigured = False
    while not reconfigured or len(received) < len(payload):
        event = client.event()
        if event["type"] == "data":
            received.extend(base64.b64decode(event["data"]))
        else:
            assert event["type"] == "reconfigured"
            assert event["baud"] == 115200
            reconfigured = True
    assert received == payload
    attrs = termios.tcgetattr(master)
    assert attrs[4] == attrs[5] == termios.B115200


@pytest.mark.parametrize(
    "command",
    [
        {"type": "write", "data": "not base64!"},
        {"type": "write", "data": base64.b64encode(b"x" * (65536 + 1)).decode()},
        {"type": "unknown"},
    ],
)
def test_invalid_or_oversized_commands_fail_closed(uart, command):
    """Fail closed on bad base64, an oversized write, or an unknown command.

    The helper reports an error, closes, exits 1, and releases the port.
    """
    _, path, start = uart
    client = start()
    assert client.event()["type"] == "ready"
    client.send(command)
    assert client.event()["type"] == "error"
    assert client.event()["type"] == "closed"
    assert client.process.wait(timeout=3) == 1
    reopened = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    os.close(reopened)


def test_stable_selection_explicit_override_and_ambiguity(tmp_path, monkeypatch):
    """Check UART selection by fallback, exact serial match, and explicit path.

    Two candidate links with no serial given, a serial that is only a prefix of
    a real one, and a wildcard serial are refused.
    """
    by_id = tmp_path / "by-id"
    by_id.mkdir()
    first = tmp_path / "ttyUSB3"
    second = tmp_path / "ttyUSB9"
    first.touch()
    second.touch()
    monkeypatch.setattr(bridge, "BY_ID", by_id)
    assert bridge.resolve_port("auto", fallback=str(first)) == first
    (by_id / "usb-FTDI_FT4232H_BOARD1-if02-port0").symlink_to(first)
    xilinx_alias = by_id / "usb-Xilinx_Alveo-ADK-2-0_BOARD2-if02-port0"
    xilinx_alias.symlink_to(second)
    assert bridge.resolve_port("auto", "BOARD2", str(first)) == xilinx_alias
    assert bridge.resolve_port(str(first), "BOARD2") == first
    with pytest.raises(bridge.BridgeError, match="Multiple"):
        bridge.resolve_port("auto")
    with pytest.raises(bridge.BridgeError, match="matches"):
        bridge.resolve_port("auto", "BOARD")
    with pytest.raises(bridge.BridgeError, match="wildcards"):
        bridge.resolve_port("auto", "BOARD*")


def test_only_a_different_xilinx_board_never_falls_back(tmp_path, monkeypatch):
    """Reject a stable X3 identity that contradicts the configured cable."""
    by_id = tmp_path / "by-id"
    by_id.mkdir()
    actual = tmp_path / "ttyUSB3"
    actual.touch()
    (by_id / "usb-Xilinx_Alveo-ADK-2-0_WRONG_BOARD-if02-port0").symlink_to(actual)
    monkeypatch.setattr(bridge, "BY_ID", by_id)
    with pytest.raises(bridge.BridgeError, match="matches"):
        bridge.resolve_port("auto", "EXPECTED_BOARD", str(actual))


def test_regular_file_and_invalid_baud_are_rejected_before_open(tmp_path, monkeypatch):
    """Refuse a regular file and an unsupported baud without touching the file."""
    path = tmp_path / "not-a-device"
    path.write_text("untouched")
    with pytest.raises(bridge.BridgeError, match="character device"):
        bridge.open_owned(path, 115200)
    with pytest.raises(bridge.BridgeError, match="Unsupported baud"):
        bridge.open_owned(path, 12345)
    assert path.read_text() == "untouched"


@pytest.mark.parametrize("denied", ["directory", "descriptor"])
@pytest.mark.parametrize("visible_reader", [False, True])
def test_hidden_descriptors_do_not_hide_readable_owners(
    uart, tmp_path, monkeypatch, denied, visible_reader
):
    """Skip descriptors hidden by permission errors but still refuse a visible reader.

    The check must not read process status, open files, or change termios.
    """
    _, port, _ = uart
    device = port.stat()
    before = termios.tcgetattr(uart[0])
    proc_root = tmp_path / "proc"
    process = proc_root / "424242"
    descriptors = process / "fd"
    descriptors.mkdir(parents=True)
    descriptor = descriptors / "7"
    descriptor.symlink_to(port)
    if visible_reader:
        visible = proc_root / "424243" / "fd"
        visible.mkdir(parents=True)
        (visible / "8").symlink_to(port)
    original_iterdir = Path.iterdir
    original_stat = Path.stat

    def protected_iterdir(path):
        if denied == "directory" and path == descriptors:
            raise PermissionError("protected descriptor directory")
        return original_iterdir(path)

    def protected_stat(path, *args, **kwargs):
        if denied == "descriptor" and path == descriptor:
            raise PermissionError("protected descriptor target")
        return original_stat(path, *args, **kwargs)

    def forbidden(*args, **kwargs):
        raise AssertionError(
            "Ownership inspection must not read process status or mutate devices"
        )

    monkeypatch.setattr(Path, "iterdir", protected_iterdir)
    monkeypatch.setattr(Path, "stat", protected_stat)
    monkeypatch.setattr(Path, "read_text", forbidden)
    monkeypatch.setattr(bridge.os, "open", forbidden)
    monkeypatch.setattr(bridge.termios, "tcsetattr", forbidden)
    monkeypatch.setattr(
        bridge, "Path", lambda path: proc_root if path == "/proc" else Path(path)
    )
    if visible_reader:
        with pytest.raises(bridge.BridgeError, match="424243.*left untouched"):
            bridge.require_unused(device)
    else:
        bridge.require_unused(device)
    assert termios.tcgetattr(uart[0]) == before


@pytest.mark.parametrize("failed", ["directory", "descriptor"])
def test_unexpected_proc_io_failure_still_refuses_open(
    uart, tmp_path, monkeypatch, failed
):
    """Fail the open on a /proc I/O error, which is not skipped like a permission error."""
    _, port, _ = uart
    process = tmp_path / "proc" / "424244"
    descriptors = process / "fd"
    descriptors.mkdir(parents=True)
    descriptor = descriptors / "7"
    descriptor.symlink_to(port)
    original_iterdir, original_stat = Path.iterdir, Path.stat

    def failing_iterdir(path):
        if failed == "directory" and path == descriptors:
            raise OSError(errno.EIO, "fixture I/O failure")
        return original_iterdir(path)

    def failing_stat(path, *args, **kwargs):
        if failed == "descriptor" and path == descriptor:
            raise OSError(errno.EIO, "fixture I/O failure")
        return original_stat(path, *args, **kwargs)

    def forbidden_open(*args, **kwargs):
        raise AssertionError(
            "Unexpected proc I/O failure must prevent opening the UART"
        )

    monkeypatch.setattr(Path, "iterdir", failing_iterdir)
    monkeypatch.setattr(Path, "stat", failing_stat)
    monkeypatch.setattr(bridge.os, "open", forbidden_open)
    monkeypatch.setattr(
        bridge, "Path", lambda path: process.parent if path == "/proc" else Path(path)
    )
    with pytest.raises(OSError, match="fixture I/O failure"):
        bridge.open_owned(port, 115200)
