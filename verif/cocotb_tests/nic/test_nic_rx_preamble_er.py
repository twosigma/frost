#    Copyright (c) 2026 John Goodacre.
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


"""GMII receive with RX_PREAMBLE_ER_TOLERANT = 1: a lone rx_er in the preamble keeps the frame.

The wrap is built as for the rx_fifo_limit test with the parameter set. One rx_er on any preamble
byte before the SFD is taken as a preamble byte and the frame is delivered (rx_gmii_preamble_er_accepted
counts it); a second rx_er in the same preamble, or an rx_er on the SFD itself, still drops the frame.
Every rx_er in a preamble is counted in rx_gmii_er_preamble either way.
"""

from typing import Any

import cocotb
from cocotb.triggers import ClockCycles

from cocotb_tests.nic.test_nic_mac_gmii import _wire_frame
from cocotb_tests.nic.test_nic_rx_fifo_limit import (
    ER_PREAMBLE,
    PRE_ACCEPT,
    PREAMBLE_DROP,
    _start,
    _total,
)


@cocotb.test()
async def lone_preamble_error_is_tolerated(dut: Any) -> None:
    """One rx_er in the preamble is accepted; two, or one on the SFD, are not."""
    peer = await _start(dut)
    peer.ready = True
    payload = bytes(range(80))
    wire = _wire_frame(payload)
    # A lone rx_er on the first preamble byte, a middle one, and the last one before the SFD.
    peer.inject(wire, error_byte=0)
    peer.inject(wire, error_byte=3)
    peer.inject(wire, error_byte=6)
    # Two errors in one preamble, and an error on the SFD (byte 7): dropped.
    peer.inject(wire, error_byte=2, extra_errors=(4,))
    peer.inject(wire, error_byte=7)
    # A clean frame.
    peer.inject(wire)
    await ClockCycles(dut.i_clk, 4000)
    assert [bytes(frame) for frame in peer.received] == [payload] * 4
    assert _total(dut, PRE_ACCEPT) == 3
    assert _total(dut, PREAMBLE_DROP) == 2
    # Three lone errors, the two separate errors of the next preamble, and the error on the SFD.
    assert _total(dut, ER_PREAMBLE) == 3 + 2 + 1


@cocotb.test()
async def errored_sfd_is_never_a_preamble_byte(dut: Any) -> None:
    """Drop the frame on an rx_er at the SFD whatever the first destination byte is."""
    peer = await _start(dut)
    peer.ready = True
    for first in (0xD5, 0x55):
        payload = bytes([first]) + bytes(range(1, 80))
        wire = _wire_frame(payload)
        dropped = _total(dut, PREAMBLE_DROP)
        accepted = _total(dut, PRE_ACCEPT)
        peer.received.clear()
        # The SFD (byte 7) errored: the frame is dropped at once, so the first destination byte
        # (0xd5 would otherwise be taken for the SFD, 0x55 for another preamble byte) starts nothing.
        peer.inject(wire, error_byte=7)
        # An errored 0xd5 as the first preamble byte (short preamble) also drops.
        peer.inject(b"\xd5" + wire[1:], error_byte=0)
        # A clean frame follows and is delivered whole.
        peer.inject(wire)
        await ClockCycles(dut.i_clk, 4000)
        assert [bytes(frame) for frame in peer.received] == [payload], hex(first)
        assert _total(dut, PREAMBLE_DROP) - dropped == 2, hex(first)
        assert _total(dut, PRE_ACCEPT) == accepted, hex(first)
