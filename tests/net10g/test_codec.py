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

"""Independent table-driven tests for the Clause 49 block format.

The test represents Figure 49-7 as a sequence of fields in transmission order;
its packing logic does not share the RTL's case branches or helper functions.
Sources:
https://www.ieee802.org/3/ap/public/sep05/szczepanek_02_0905.pdf
https://www.ieee802.org/3/ca/public/meeting_archive/2018/01/remein_3ca_1_0118.pdf
The first source reproduces Clause 49's block table in a KR proposal. Its
proposed CRC8 extension is not part of this MAC/PCS.
"""

import random

import cocotb
from typing import Any
from cocotb.triggers import Timer

CODES = {
    0x07: 0x00,
    0x06: 0x06,
    0xFE: 0x1E,
    0x1C: 0x2D,
    0x3C: 0x33,
    0x7C: 0x4B,
    0xBC: 0x55,
    0xDC: 0x66,
    0xF7: 0x78,
}
O_CODES = {0x9C: 0x0, 0x5C: 0xF}
# (type, XGMII lane pattern, payload field sequence); '_' is a padding bit.
FORMATS = [
    (0x1E, "CCCCCCCC", "C0 C1 C2 C3 C4 C5 C6 C7"),
    (0x2D, "CCCCODDD", "C0 C1 C2 C3 O4 D5 D6 D7"),
    (0x33, "CCCCSDDD", "C0 C1 C2 C3 _ _ _ _ D5 D6 D7"),
    (0x66, "ODDDSDDD", "D1 D2 D3 O0 _ _ _ _ D5 D6 D7"),
    (0x55, "ODDDODDD", "D1 D2 D3 O0 O4 D5 D6 D7"),
    (0x78, "SDDDDDDD", "D1 D2 D3 D4 D5 D6 D7"),
    (0x4B, "ODDDCCCC", "D1 D2 D3 O0 C4 C5 C6 C7"),
    (0x87, "TCCCCCCC", "_ _ _ _ _ _ _ C1 C2 C3 C4 C5 C6 C7"),
    (0x99, "DTCCCCCC", "D0 _ _ _ _ _ _ C2 C3 C4 C5 C6 C7"),
    (0xAA, "DDTCCCCC", "D0 D1 _ _ _ _ _ C3 C4 C5 C6 C7"),
    (0xB4, "DDDTCCCC", "D0 D1 D2 _ _ _ _ C4 C5 C6 C7"),
    (0xCC, "DDDDTCCC", "D0 D1 D2 D3 _ _ _ C5 C6 C7"),
    (0xD2, "DDDDDTCC", "D0 D1 D2 D3 D4 _ _ C6 C7"),
    (0xE1, "DDDDDDTC", "D0 D1 D2 D3 D4 D5 _ C7"),
    (0xFF, "DDDDDDDT", "D0 D1 D2 D3 D4 D5 D6"),
]
FORMAT_BY_TYPE = {fmt[0]: fmt for fmt in FORMATS}
ERROR_WORD = int.from_bytes(b"\xfe" * 8, "little")
ERROR_PAYLOAD = 0x1E | sum(0x1E << (8 + 7 * lane) for lane in range(8))


def pack_octets(octets: list[int]) -> int:
    """Pack octets with lane zero at the least significant byte."""
    return int.from_bytes(bytes(octets), "little")


def pack_format(fmt: tuple[int, str, str], octets: list[int], padding: int = 0) -> int:
    """Serialize a table row into its payload fields."""
    block_type, _, fields = fmt
    result, offset = block_type, 8
    for field in fields.split():
        kind = field[0]
        if kind == "_":
            width, value = 1, padding
        else:
            value = octets[int(field[1])]
            if kind == "C":
                width, value = 7, CODES[value]
            elif kind == "O":
                width, value = 4, O_CODES[value]
            else:
                width = 8
        result |= value << offset
        offset += width
    assert offset == 64
    return result


def encode_reference(octets: list[int], ctrl: int) -> tuple[int, int, int]:
    """Find a representable XGMII word in the independent format table."""
    if ctrl == 0:
        return pack_octets(octets), 2, 0
    for fmt in FORMATS:
        matches = True
        for lane, kind in enumerate(fmt[1]):
            value, control = octets[lane], (ctrl >> lane) & 1
            matches &= not control if kind == "D" else bool(control)
            if kind == "C":
                matches &= value in CODES
            elif kind == "O":
                matches &= value in O_CODES
            elif kind == "S":
                matches &= value == 0xFB
            elif kind == "T":
                matches &= value == 0xFD
        if matches:
            return pack_format(fmt, octets), 1, 0
    return ERROR_PAYLOAD, 1, 1


def decode_reference(payload: int, header: int) -> tuple[int, int, int]:
    """Decode a payload by iterating the independent format description."""
    if header == 2:
        return payload, 0, 0
    if header != 1 or payload & 255 not in FORMAT_BY_TYPE:
        return ERROR_WORD, 255, 1
    fmt = FORMAT_BY_TYPE[payload & 255]
    lanes, ctrl = [0] * 8, 0
    for lane, kind in enumerate(fmt[1]):
        if kind != "D":
            ctrl |= 1 << lane
        if kind in "ST":
            lanes[lane] = {"S": 0xFB, "T": 0xFD}[kind]
    inverse_c = {v: k for k, v in CODES.items()}
    inverse_o = {v: k for k, v in O_CODES.items()}
    offset = 8
    for field in fmt[2].split():
        kind = field[0]
        width = {"_": 1, "D": 8, "C": 7, "O": 4}[kind]
        value = (payload >> offset) & ((1 << width) - 1)
        offset += width
        if kind == "_":
            continue
        if kind == "C":
            if value not in inverse_c:
                return ERROR_WORD, 255, 1
            value = inverse_c[value]
        elif kind == "O":
            if value not in inverse_o:
                return ERROR_WORD, 255, 1
            value = inverse_o[value]
        lanes[int(field[1])] = value
    return pack_octets(lanes), ctrl, 0


async def check_encoder(dut: Any, octets: list[int], ctrl: int) -> None:
    """Compare the encoder against the table model."""
    dut.tx_data.value = pack_octets(octets)
    dut.tx_ctrl.value = ctrl
    await Timer(1, unit="ns")
    actual = tuple(
        int(signal.value) for signal in (dut.tx_payload, dut.tx_header, dut.tx_bad)
    )
    assert actual == encode_reference(octets, ctrl), (octets, ctrl, actual)


async def check_decoder(dut: Any, payload: int, header: int) -> None:
    """Compare the decoder against the table model."""
    dut.rx_payload.value = payload
    dut.rx_header.value = header
    await Timer(1, unit="ns")
    actual = tuple(
        int(signal.value) for signal in (dut.rx_data, dut.rx_ctrl, dut.rx_bad)
    )
    assert actual == decode_reference(payload, header), (hex(payload), header, actual)


def random_lanes(fmt: tuple[int, str, str], rng: random.Random) -> list[int]:
    """Generate a legal XGMII word for a given format."""
    result = []
    for kind in fmt[1]:
        if kind == "C":
            result.append(rng.choice(list(CODES)))
        elif kind == "O":
            result.append(rng.choice(list(O_CODES)))
        elif kind in "ST":
            result.append({"S": 0xFB, "T": 0xFD}[kind])
        else:
            result.append(rng.randrange(256))
    return result


@cocotb.test()
async def published_vector_and_legal_formats(dut: Any) -> None:
    """Check the published vector, every format, C codes and ignored padding."""
    # Published encoded vector, independent of both RTL and table packer:
    # https://www.ieee802.org/3/10G_study/email/msg03521.html
    published_input = [0x07, 0xFE, 0x1C, 0x3C, 0x7C, 0xBC, 0xDC, 0xF7]
    published_payload = 0xF19AACB66B4F001E
    assert pack_format(FORMATS[0], published_input) == published_payload
    await check_encoder(dut, published_input, 255)
    assert int(dut.tx_payload.value) == published_payload
    assert int(dut.tx_header.value) == 1  # Serialized 1, 0.
    await check_decoder(dut, published_payload, 1)

    rng = random.Random(0x640066)
    for fmt in FORMATS:
        for _ in range(128):
            lanes = random_lanes(fmt, rng)
            ctrl = sum((kind != "D") << lane for lane, kind in enumerate(fmt[1]))
            await check_encoder(dut, lanes, ctrl)
            await check_decoder(dut, pack_format(fmt, lanes), 1)
            # Reserved bits are ignored on receive, not misreported as errors.
            await check_decoder(dut, pack_format(fmt, lanes, padding=1), 1)
    for _ in range(512):
        lanes = [rng.randrange(256) for _ in range(8)]
        await check_encoder(dut, lanes, 0)
        await check_decoder(dut, pack_octets(lanes), 2)


@cocotb.test()
async def malformed_fields_and_xgmii(dut: Any) -> None:
    """Exercise every C and O code, unknown types, illegal words and headers."""
    rng = random.Random(0xBAD66)
    # Every C-code value in every C field, including all unused codes.
    for lane in range(8):
        for code in range(128):
            await check_decoder(dut, 0x1E | (code << (8 + 7 * lane)), 1)
        for octet in range(256):
            lanes = [0x07] * 8
            lanes[lane] = octet
            await check_encoder(dut, lanes, 255)
    # Every O-code value in every O-code position of every applicable format.
    for fmt in FORMATS:
        lanes = random_lanes(fmt, rng)
        offset = 8
        for field in fmt[2].split():
            width = {"_": 1, "D": 8, "C": 7, "O": 4}[field[0]]
            if field[0] == "O":
                for code in range(16):
                    payload = pack_format(fmt, lanes) & ~(15 << offset)
                    await check_decoder(dut, payload | (code << offset), 1)
            offset += width
    for block_type in range(256):
        await check_decoder(dut, block_type, 1)
    for _ in range(4000):
        payload = rng.getrandbits(64)
        await check_decoder(dut, payload, rng.randrange(4))
        # Mix controls with arbitrary bytes to exercise otherwise plausible masks.
        choices = list(CODES) + list(O_CODES) + [0xFB, 0xFD, rng.randrange(256)]
        await check_encoder(
            dut, [rng.choice(choices) for _ in range(8)], rng.randrange(256)
        )
