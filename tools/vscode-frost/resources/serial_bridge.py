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

"""Hold one Linux UART exclusively and bridge its bytes over newline-delimited JSON.

Commands on stdin: {"type":"write","data":"<base64>"}, {"type":"reconfigure"}
and {"type":"close"}. Events on stdout: ready(port, baud), data(base64),
reconfigured(port, baud), error(message) and closed. A malformed command is an
error that ends the bridge. Stdin EOF, SIGTERM or SIGINT closes the port. No
command flushes pending input.

Before changing termios, the bridge looks in /proc for other processes holding
the device, takes flock and TIOCEXCL, then looks again to catch a process that
opened it between the first look and the open. TIOCEXCL refuses later
unprivileged opens; flock coordinates cooperating clients. Linux may hide a
process's descriptors even from the same user, and those are skipped, so a
holder the bridge cannot see goes undetected; a CAP_SYS_ADMIN process can also
bypass TIOCEXCL. The bridge never touches another process or its descriptors,
and does not restore the old termios settings on close.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import select
import selectors
import signal
import stat
import sys
import termios
import time
from typing import Any

DEFAULT_PORT = "/dev/ttyUSB3"  # X3 default in fpga/common/hw_defaults.py.
BY_ID = Path("/dev/serial/by-id")
MAX_BUFFER = 1024 * 1024
MAX_COMMAND = 128 * 1024
MAX_TRANSMIT = 64 * 1024
BAUD_RATES = {
    speed: getattr(termios, f"B{speed}")
    for speed in (
        50,
        75,
        110,
        134,
        150,
        200,
        300,
        600,
        1200,
        1800,
        2400,
        4800,
        9600,
        19200,
        38400,
        57600,
        115200,
        230400,
        460800,
        500000,
        576000,
        921600,
        1000000,
        1152000,
        1500000,
        2000000,
        2500000,
        3000000,
        3500000,
        4000000,
    )
    if hasattr(termios, f"B{speed}")
}


class BridgeError(Exception):
    """A failure reported to the extension as an error event."""


def resolve_port(port: str, serial: str = "", fallback: str = DEFAULT_PORT) -> Path:
    """Return the UART to open.

    An explicit ``port`` is used as given. For "auto", the one FT4232H ``if02``
    UART in /dev/serial/by-id is chosen; with ``serial`` set, it must match
    that serial. If no FT4232H UART is present, ``fallback`` is used.
    """
    if port != "auto":
        if not port:
            raise BridgeError("Serial port must be a path or 'auto'")
        return Path(port).resolve(strict=True)
    candidates = sorted(
        entry
        for entry in BY_ID.glob("*")
        if (
            "ft4232" in entry.name.lower()
            or entry.name.lower().startswith("usb-xilinx_alveo-adk-2-0_")
        )
        and re.search(r"-if02(?:-|$)", entry.name)
    )
    if serial:
        if not re.fullmatch(r"[A-Za-z0-9_-]+", serial):
            raise BridgeError("JTAG serial must be an exact serial, without wildcards")
        matched = [
            p
            for p in candidates
            if re.search(rf"(?:^|_){re.escape(serial)}-if02(?:-|$)", p.name)
        ]
        if candidates and not matched:
            raise BridgeError(
                "No FT4232H UART identity matches the configured JTAG serial"
            )
        candidates = matched
    # Several by-id links can name one device; keep one stable name per device.
    identities: dict[tuple[str, int | str], Path] = {}
    for candidate in candidates:
        target = candidate.resolve(strict=True)
        info = target.stat()
        identity = (
            ("device", info.st_rdev)
            if stat.S_ISCHR(info.st_mode)
            else ("path", str(target))
        )
        identities.setdefault(identity, candidate.absolute())
    if len(identities) > 1:
        raise BridgeError(
            "Multiple FT4232H UARTs found; configure an explicit serial port"
        )
    return (
        next(iter(identities.values()))
        if identities
        else Path(fallback).resolve(strict=True)
    )


def device_readers(device: os.stat_result, own_fd: int | None = None) -> list[int]:
    """Return the PIDs of visible processes that hold this device under any name."""
    owners = set()
    for process in Path("/proc").iterdir():
        if not process.name.isdecimal():
            continue
        try:
            descriptors = list((process / "fd").iterdir())
        except FileNotFoundError:
            continue
        except PermissionError:
            # /proc access uses ptrace policy, not merely matching UID/caps.
            continue
        for descriptor in descriptors:
            if int(process.name) == os.getpid() and descriptor.name == str(own_fd):
                continue
            try:
                opened = descriptor.stat()
            except FileNotFoundError:
                continue
            except PermissionError:
                continue
            if stat.S_ISCHR(opened.st_mode) and opened.st_rdev == device.st_rdev:
                owners.add(int(process.name))
    return sorted(owners)


def require_unused(device: os.stat_result, own_fd: int | None = None) -> None:
    """Raise if another visible process holds the device."""
    owners = device_readers(device, own_fd)
    if owners:
        raise BridgeError(
            f"Serial port is already open by PID(s) {', '.join(map(str, owners))}; left untouched"
        )


def force_baud(fd: int, baud: int) -> None:
    """Set raw 8N1 at ``baud`` on our descriptor without flushing received bytes.

    The reconfigure command runs it again. The extension sends that command
    after JTAG activity on the FT4232H, which can change the UART's settings.
    """
    if baud not in BAUD_RATES:
        raise BridgeError(
            f"Unsupported baud {baud}; choose one of {sorted(BAUD_RATES)}"
        )
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = BAUD_RATES[baud]
    attrs[5] = BAUD_RATES[baud]
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def open_owned(port: Path, baud: int) -> int:
    """Open the port exclusively and configure it; on failure undo only our TIOCEXCL."""
    if baud not in BAUD_RATES:
        raise BridgeError(f"Unsupported baud {baud}")
    expected = port.stat()
    if not stat.S_ISCHR(expected.st_mode):
        raise BridgeError("Serial port must be a character device")
    require_unused(expected)
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK | os.O_CLOEXEC)
    exclusive = False
    try:
        opened = os.fstat(fd)
        if opened.st_rdev != expected.st_rdev or not stat.S_ISCHR(opened.st_mode):
            raise BridgeError("Serial device changed while it was being opened")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        require_unused(opened, fd)
        fcntl.ioctl(fd, termios.TIOCEXCL)
        exclusive = True
        require_unused(opened, fd)
        force_baud(fd, baud)
        return fd
    except BaseException:
        try:
            if exclusive:
                fcntl.ioctl(fd, termios.TIOCNXCL)
        finally:
            os.close(fd)
        raise


def close_owned(fd: int) -> None:
    """Release our fd and exclusive-open flag without flushing pending bytes."""
    try:
        try:
            fcntl.ioctl(fd, termios.TIOCNXCL)
        except OSError as error:
            if error.errno not in (errno.EIO, errno.ENODEV, errno.ENXIO, errno.ENOTTY):
                raise
    finally:
        os.close(fd)


class Bridge:
    """Relay bytes between the UART and the JSON pipes.

    The pipes are nonblocking, so stdin EOF or the parent's exit is noticed
    even while output is backed up.
    """

    def __init__(self, fd: int, port: Path, baud: int):
        """Register the acquired UART and the parent's protocol pipes."""
        self.fd: int | None = fd
        self.port, self.baud = str(port), baud
        self.selector = selectors.DefaultSelector()
        self.input = bytearray()
        self.output = bytearray()
        self.transmit = bytearray()
        self.closing = False
        self.close_deadline = 0.0
        self.stdout_registered = False
        os.set_blocking(0, False)
        os.set_blocking(1, False)
        self.selector.register(0, selectors.EVENT_READ, "input")
        self.selector.register(fd, selectors.EVENT_READ, "serial")

    def emit(self, kind: str, **values: Any) -> None:
        """Queue one event as a whole JSON line."""
        self.output.extend((json.dumps({"type": kind, **values}) + "\n").encode())
        if len(self.output) > MAX_BUFFER:
            raise BridgeError("Serial output consumer cannot keep up")
        if not self.stdout_registered:
            self.selector.register(1, selectors.EVENT_WRITE, "output")
            self.stdout_registered = True

    def close(self) -> None:
        """Close the UART, stop reading commands, and queue the closed event."""
        if self.closing:
            return
        self.closing = True
        self.close_deadline = time.monotonic() + 0.5
        self.selector.unregister(0)
        if self.fd is not None:
            fd, self.fd = self.fd, None
            self.selector.unregister(fd)
            close_owned(fd)
        self.emit("closed")

    def command(self, raw: bytes) -> None:
        """Validate and execute one complete JSON command."""
        try:
            command = json.loads(raw)
            if not isinstance(command, dict):
                raise ValueError("command must be an object")
            kind = command.get("type")
            if kind == "close":
                self.close()
            elif kind == "reconfigure":
                assert self.fd is not None
                force_baud(self.fd, self.baud)
                self.emit("reconfigured", port=self.port, baud=self.baud)
            elif kind == "write":
                data = command.get("data")
                if not isinstance(data, str):
                    raise ValueError("write.data must be base64 text")
                decoded = base64.b64decode(data, validate=True)
                if len(self.transmit) + len(decoded) > MAX_TRANSMIT:
                    raise ValueError(
                        "serial write queue exceeds 64 KiB; paste a smaller chunk"
                    )
                self.transmit.extend(decoded)
                assert self.fd is not None
                self.selector.modify(
                    self.fd, selectors.EVENT_READ | selectors.EVENT_WRITE, "serial"
                )
            else:
                raise ValueError(f"unknown command type {kind!r}")
        except (ValueError, UnicodeError, binascii.Error) as error:
            raise BridgeError(f"Invalid serial command: {error}") from error

    def run(self) -> int:
        """Transfer bytes until close, EOF, failure, or parent termination."""
        self.emit("ready", port=self.port, baud=self.baud)
        while not self.closing or self.output:
            if self.closing and time.monotonic() >= self.close_deadline:
                break
            for key, mask in self.selector.select(0.1):
                if key.data == "output":
                    try:
                        count = os.write(1, self.output)
                    except BlockingIOError:
                        continue
                    del self.output[:count]
                    if not self.output:
                        self.selector.unregister(1)
                        self.stdout_registered = False
                elif self.closing:
                    continue
                elif key.data == "input":
                    data = os.read(0, 65536)
                    if not data:
                        self.close()
                        continue
                    self.input.extend(data)
                    if len(self.input) > MAX_COMMAND:
                        raise BridgeError("Serial command exceeds 128 KiB")
                    while b"\n" in self.input and not self.closing:
                        line, _, remaining = self.input.partition(b"\n")
                        self.input = remaining
                        self.command(line)
                else:
                    assert self.fd is not None
                    if mask & selectors.EVENT_READ:
                        try:
                            data = os.read(self.fd, 4096)
                        except BlockingIOError:
                            data = None
                        if data == b"":
                            raise BridgeError("Serial device disconnected")
                        if data:
                            self.emit(
                                "data", data=base64.b64encode(data).decode("ascii")
                            )
                    if mask & selectors.EVENT_WRITE and self.transmit:
                        try:
                            count = os.write(self.fd, self.transmit)
                        except BlockingIOError:
                            count = 0
                        del self.transmit[:count]
                    if not self.transmit:
                        self.selector.modify(self.fd, selectors.EVENT_READ, "serial")
        return 0

    def flush_output(self) -> None:
        """Finish queued JSON after closing the device, with a bounded wait."""
        deadline = time.monotonic() + 0.5
        while self.output and time.monotonic() < deadline:
            if select.select([], [1], [], max(0, deadline - time.monotonic()))[1]:
                try:
                    count = os.write(1, self.output)
                except BlockingIOError:
                    continue
                del self.output[:count]


def main() -> int:
    """Open the selected UART and run the bridge until it closes."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default="auto")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--jtag-serial", default="")
    parser.add_argument(
        "--fallback-port",
        default=DEFAULT_PORT,
        help="port for --port auto when no FT4232H UART is found",
    )
    args = parser.parse_args()
    fd = None
    bridge = None

    def stop(_signal: int, _frame: Any) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        if sys.platform != "linux":
            raise BridgeError("Serial bridge requires Linux")
        port = resolve_port(args.port, args.jtag_serial, args.fallback_port)
        fd = open_owned(port, args.baud)
        bridge = Bridge(fd, port, args.baud)
        return bridge.run()
    except KeyboardInterrupt:
        return 0
    except (BridgeError, OSError, termios.error) as error:
        message = str(error)
        if isinstance(error, OSError) and error.errno in (errno.EBUSY, errno.EAGAIN):
            message = "Serial port is in use by another program; left untouched"
        try:
            if bridge is not None:
                bridge.emit("error", message=message)
                bridge.close()
                bridge.flush_output()
            else:
                os.write(
                    1,
                    (json.dumps({"type": "error", "message": message}) + "\n").encode(),
                )
        except (OSError, BridgeError):
            pass
        return 1
    finally:
        if bridge is not None:
            if bridge.fd is not None:
                close_owned(bridge.fd)
            bridge.selector.close()
        elif fd is not None:
            close_owned(fd)


if __name__ == "__main__":
    raise SystemExit(main())
