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

"""Unit tests for the IF-stage RVC decompressor."""

from typing import Any

import cocotb
from cocotb.triggers import Timer


OPC_LUI = 0b0110111
OPC_JAL = 0b1101111
OPC_JALR = 0b1100111
OPC_BRANCH = 0b1100011
OPC_LOAD = 0b0000011
OPC_STORE = 0b0100011
OPC_OP_IMM = 0b0010011
OPC_OP = 0b0110011


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


def _sign_extend(value: int, width: int) -> int:
    """Sign-extend a value and return it as a Python integer."""
    sign_bit = 1 << (width - 1)
    mask = (1 << width) - 1
    value &= mask
    return value - (1 << width) if value & sign_bit else value


def _pack_i(*, imm: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
    """Pack an I-type instruction."""
    return (
        ((imm & 0xFFF) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def _pack_s(*, imm: int, rs2: int, rs1: int, funct3: int, opcode: int) -> int:
    """Pack an S-type instruction."""
    return (
        (((imm >> 5) & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((imm & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def _pack_r(
    *,
    funct7: int,
    rs2: int,
    rs1: int,
    funct3: int,
    rd: int,
    opcode: int,
) -> int:
    """Pack an R-type instruction."""
    return (
        ((funct7 & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def _pack_u(*, imm20: int, rd: int, opcode: int) -> int:
    """Pack a U-type instruction."""
    return ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def _pack_compressed(*, funct3: int, quadrant: int, bits12_2: int) -> int:
    """Pack common compressed fields."""
    return ((funct3 & 0x7) << 13) | ((bits12_2 & 0x7FF) << 2) | (quadrant & 0x3)


def _rd_prime(raw: int) -> int:
    """Return the expanded compressed rd' register."""
    return 8 + ((raw >> 2) & 0x7)


def _rs1_prime(raw: int) -> int:
    """Return the expanded compressed rs1' register."""
    return 8 + ((raw >> 7) & 0x7)


def _rs2_prime(raw: int) -> int:
    """Return the expanded compressed rs2' register."""
    return 8 + ((raw >> 2) & 0x7)


def _imm_addi4spn(raw: int) -> int:
    """Decode the C.ADDI4SPN immediate."""
    return (
        (((raw >> 7) & 0xF) << 6)
        | (((raw >> 11) & 0x3) << 4)
        | (((raw >> 5) & 0x1) << 3)
        | (((raw >> 6) & 0x1) << 2)
    )


def _imm_lw_sw(raw: int) -> int:
    """Decode the C.LW/C.SW immediate."""
    return (
        (((raw >> 5) & 0x1) << 6)
        | (((raw >> 10) & 0x7) << 3)
        | (((raw >> 6) & 0x1) << 2)
    )


def _imm_ci(raw: int) -> int:
    """Decode the CI-format sign-extended immediate."""
    value = (((raw >> 12) & 0x1) << 5) | ((raw >> 2) & 0x1F)
    return _sign_extend(value, 6)


def _imm_addi16sp(raw: int) -> int:
    """Decode the C.ADDI16SP immediate."""
    value = (
        (((raw >> 12) & 0x1) << 9)
        | (((raw >> 3) & 0x3) << 7)
        | (((raw >> 5) & 0x1) << 6)
        | (((raw >> 2) & 0x1) << 5)
        | (((raw >> 6) & 0x1) << 4)
    )
    return _sign_extend(value, 10)


def _imm_lui(raw: int) -> int:
    """Decode the C.LUI upper immediate."""
    value = (((raw >> 12) & 0x1) << 5) | ((raw >> 2) & 0x1F)
    return _sign_extend(value, 6) & 0xFFFFF


def _imm_lwsp(raw: int) -> int:
    """Decode the C.LWSP immediate."""
    return (
        (((raw >> 2) & 0x3) << 6)
        | (((raw >> 12) & 0x1) << 5)
        | (((raw >> 4) & 0x7) << 2)
    )


def _imm_swsp(raw: int) -> int:
    """Decode the C.SWSP immediate."""
    return (((raw >> 7) & 0x3) << 6) | (((raw >> 9) & 0xF) << 2)


def _drive(dut: Any, raw: int) -> None:
    """Drive one compressed instruction parcel."""
    dut.i_instr_compressed.value = raw


def _assert_decode(
    dut: Any,
    *,
    expanded: int,
    compressed: bool = True,
    illegal: bool = False,
) -> None:
    """Assert decompressor outputs."""
    assert int(dut.o_instr_expanded.value) == expanded
    assert bool(dut.o_is_compressed.value) is compressed
    assert bool(dut.o_illegal.value) is illegal


@cocotb.test()
async def test_quadrant3_non_compressed_parcel_passes_through(dut: Any) -> None:
    """A quadrant-3 parcel is treated as uncompressed and zero-extended."""
    raw = 0xABCF

    _drive(dut, raw)
    await _settle()

    _assert_decode(dut, expanded=raw, compressed=False)


@cocotb.test()
async def test_c_addi4spn_expands_and_zero_immediate_is_illegal(dut: Any) -> None:
    """C.ADDI4SPN expands to ADDI xN, x2, nzuimm and rejects zero immediates."""
    raw = (
        (0b000 << 13)
        | (0b01 << 11)
        | (0b1010 << 7)
        | (0 << 6)
        | (1 << 5)
        | (3 << 2)
        | 0b00
    )

    _drive(dut, raw)
    await _settle()

    _assert_decode(
        dut,
        expanded=_pack_i(
            imm=_imm_addi4spn(raw),
            rs1=2,
            funct3=0b000,
            rd=_rd_prime(raw),
            opcode=OPC_OP_IMM,
        ),
    )

    zero_imm_raw = (0b000 << 13) | (1 << 2) | 0b00
    _drive(dut, zero_imm_raw)
    await _settle()

    _assert_decode(
        dut,
        expanded=_pack_i(
            imm=0,
            rs1=2,
            funct3=0b000,
            rd=_rd_prime(zero_imm_raw),
            opcode=OPC_OP_IMM,
        ),
        illegal=True,
    )


@cocotb.test()
async def test_quadrant0_load_and_store_expansions(dut: Any) -> None:
    """Quadrant-0 C.LW and C.SW expand with compressed register mapping."""
    lw_raw = _pack_compressed(
        funct3=0b010,
        quadrant=0b00,
        bits12_2=(0b101 << 8) | (2 << 5) | (1 << 4) | (1 << 3) | 4,
    )
    _drive(dut, lw_raw)
    await _settle()

    _assert_decode(
        dut,
        expanded=_pack_i(
            imm=_imm_lw_sw(lw_raw),
            rs1=_rs1_prime(lw_raw),
            funct3=0b010,
            rd=_rd_prime(lw_raw),
            opcode=OPC_LOAD,
        ),
    )

    sw_raw = _pack_compressed(
        funct3=0b110,
        quadrant=0b00,
        bits12_2=(0b011 << 8) | (5 << 5) | (1 << 4) | (0 << 3) | 6,
    )
    _drive(dut, sw_raw)
    await _settle()

    _assert_decode(
        dut,
        expanded=_pack_s(
            imm=_imm_lw_sw(sw_raw),
            rs2=_rs2_prime(sw_raw),
            rs1=_rs1_prime(sw_raw),
            funct3=0b010,
            opcode=OPC_STORE,
        ),
    )


@cocotb.test()
async def test_c_addi_and_c_li_sign_extend_ci_immediates(dut: Any) -> None:
    """CI-format arithmetic immediates are sign-extended into ADDI encodings."""
    addi_raw = _pack_compressed(
        funct3=0b000,
        quadrant=0b01,
        bits12_2=(1 << 10) | (7 << 5) | 0b11100,
    )
    _drive(dut, addi_raw)
    await _settle()

    _assert_decode(
        dut,
        expanded=_pack_i(
            imm=_imm_ci(addi_raw),
            rs1=7,
            funct3=0b000,
            rd=7,
            opcode=OPC_OP_IMM,
        ),
    )

    li_raw = _pack_compressed(
        funct3=0b010,
        quadrant=0b01,
        bits12_2=(0 << 10) | (9 << 5) | 0b00101,
    )
    _drive(dut, li_raw)
    await _settle()

    _assert_decode(
        dut,
        expanded=_pack_i(
            imm=_imm_ci(li_raw),
            rs1=0,
            funct3=0b000,
            rd=9,
            opcode=OPC_OP_IMM,
        ),
    )


@cocotb.test()
async def test_c_lui_and_c_addi16sp_expand_and_reject_zero_immediates(
    dut: Any,
) -> None:
    """C.LUI and C.ADDI16SP expand and reject architecturally invalid immediates."""
    lui_raw = _pack_compressed(
        funct3=0b011,
        quadrant=0b01,
        bits12_2=(1 << 10) | (10 << 5) | 0b10000,
    )
    _drive(dut, lui_raw)
    await _settle()

    _assert_decode(
        dut,
        expanded=_pack_u(imm20=_imm_lui(lui_raw), rd=10, opcode=OPC_LUI),
    )

    addi16sp_raw = _pack_compressed(
        funct3=0b011,
        quadrant=0b01,
        bits12_2=(0 << 10) | (2 << 5) | 0b10110,
    )
    _drive(dut, addi16sp_raw)
    await _settle()

    _assert_decode(
        dut,
        expanded=_pack_i(
            imm=_imm_addi16sp(addi16sp_raw),
            rs1=2,
            funct3=0b000,
            rd=2,
            opcode=OPC_OP_IMM,
        ),
    )

    for illegal_raw in (
        # C.LUI rd!=0 with imm==0 is reserved; C.ADDI16SP with imm==0 is
        # reserved. (C.LUI rd=0 with imm!=0 is a HINT, not illegal -- see
        # test_rvc_rd0_hints_are_legal_nops.)
        _pack_compressed(funct3=0b011, quadrant=0b01, bits12_2=(10 << 5)),
        _pack_compressed(funct3=0b011, quadrant=0b01, bits12_2=(2 << 5)),
    ):
        _drive(dut, illegal_raw)
        await _settle()

        assert bool(dut.o_illegal.value) is True


@cocotb.test()
async def test_quadrant1_alu_group_expands_and_rejects_rv64_only_ops(
    dut: Any,
) -> None:
    """Quadrant-1 ALU group expands RV32 ops and marks RV64-only encodings illegal."""
    sub_raw = _pack_compressed(
        funct3=0b100,
        quadrant=0b01,
        bits12_2=(0 << 10) | (0b11 << 8) | (3 << 5) | (0b00 << 3) | 4,
    )
    _drive(dut, sub_raw)
    await _settle()

    _assert_decode(
        dut,
        expanded=_pack_r(
            funct7=0b0100000,
            rs2=_rs2_prime(sub_raw),
            rs1=_rs1_prime(sub_raw),
            funct3=0b000,
            rd=_rs1_prime(sub_raw),
            opcode=OPC_OP,
        ),
    )

    illegal_rv64_raw = sub_raw | (1 << 12)
    _drive(dut, illegal_rv64_raw)
    await _settle()

    assert bool(dut.o_illegal.value) is True


@cocotb.test()
async def test_quadrant2_lwsp_swsp_and_register_ops(dut: Any) -> None:
    """Quadrant-2 stack and register operations expand to base ISA forms."""
    lwsp_raw = _pack_compressed(
        funct3=0b010,
        quadrant=0b10,
        bits12_2=(1 << 10) | (11 << 5) | 0b10101,
    )
    _drive(dut, lwsp_raw)
    await _settle()

    _assert_decode(
        dut,
        expanded=_pack_i(
            imm=_imm_lwsp(lwsp_raw),
            rs1=2,
            funct3=0b010,
            rd=11,
            opcode=OPC_LOAD,
        ),
    )

    swsp_raw = _pack_compressed(
        funct3=0b110,
        quadrant=0b10,
        bits12_2=(0b101001 << 5) | 13,
    )
    _drive(dut, swsp_raw)
    await _settle()

    _assert_decode(
        dut,
        expanded=_pack_s(
            imm=_imm_swsp(swsp_raw),
            rs2=13,
            rs1=2,
            funct3=0b010,
            opcode=OPC_STORE,
        ),
    )

    add_raw = _pack_compressed(
        funct3=0b100,
        quadrant=0b10,
        bits12_2=(1 << 10) | (12 << 5) | 14,
    )
    _drive(dut, add_raw)
    await _settle()

    _assert_decode(
        dut,
        expanded=_pack_r(
            funct7=0,
            rs2=14,
            rs1=12,
            funct3=0,
            rd=12,
            opcode=OPC_OP,
        ),
    )


@cocotb.test()
async def test_quadrant2_jr_jalr_ebreak_and_illegal_rd_zero(dut: Any) -> None:
    """Quadrant-2 control encodings expand and reject invalid rd=x0 cases."""
    jr_raw = _pack_compressed(
        funct3=0b100,
        quadrant=0b10,
        bits12_2=(0 << 10) | (5 << 5),
    )
    _drive(dut, jr_raw)
    await _settle()

    _assert_decode(
        dut,
        expanded=_pack_i(imm=0, rs1=5, funct3=0, rd=0, opcode=OPC_JALR),
    )

    jalr_raw = jr_raw | (1 << 12)
    _drive(dut, jalr_raw)
    await _settle()

    _assert_decode(
        dut,
        expanded=_pack_i(imm=0, rs1=5, funct3=0, rd=1, opcode=OPC_JALR),
    )

    ebreak_raw = _pack_compressed(funct3=0b100, quadrant=0b10, bits12_2=(1 << 10))
    _drive(dut, ebreak_raw)
    await _settle()

    _assert_decode(dut, expanded=0x00100073)

    illegal_jr_raw = _pack_compressed(funct3=0b100, quadrant=0b10, bits12_2=0)
    _drive(dut, illegal_jr_raw)
    await _settle()

    assert bool(dut.o_illegal.value) is True


@cocotb.test()
async def test_shift_and_lwsp_rd_zero_illegal_cases(dut: Any) -> None:
    """C.SLLI rejects RV32 shamt[5]=1; C.LWSP rejects rd=x0.

    (C.SLLI rd=x0 is NOT illegal -- it is a HINT; see
    test_rvc_rd0_hints_are_legal_nops.)
    """
    for raw in (
        _pack_compressed(funct3=0b000, quadrant=0b10, bits12_2=(1 << 10) | (3 << 5)),
        _pack_compressed(funct3=0b010, quadrant=0b10, bits12_2=0b00101),
    ):
        _drive(dut, raw)
        await _settle()

        assert bool(dut.o_illegal.value) is True


@cocotb.test()
async def test_rvc_rd0_hints_are_legal_nops(dut: Any) -> None:
    """rd=x0 forms of C.ADD/C.MV/C.LUI/C.SLLI are HINTs that must nop.

    They expand to a write of x0 (architectural nop) and must NOT raise
    illegal. Regression for the cadd arch-test livelock: these were wrongly
    flagged illegal, and with no trap handler the trap looped to mtvec=0.
    """
    for raw, name in (
        (0x900A, "c.add x0,x2"),  # C.ADD rd=0 (rs2!=0)
        (0x800A, "c.mv x0,x2"),  # C.MV  rd=0 (rs2!=0)
        # C.LUI x0, imm!=0  and  C.SLLI x0, shamt!=0
        (_pack_compressed(funct3=0b011, quadrant=0b01, bits12_2=0b10000), "c.lui x0"),
        (_pack_compressed(funct3=0b000, quadrant=0b10, bits12_2=0b00101), "c.slli x0"),
    ):
        _drive(dut, raw)
        await _settle()
        assert (
            bool(dut.o_illegal.value) is False
        ), f"{name} ({raw:#06x}) flagged illegal"
        # Expanded instruction must target x0 (rd = bits[11:7]) -> nop.
        assert (
            (int(dut.o_instr_expanded.value) >> 7) & 0x1F
        ) == 0, f"{name} ({raw:#06x}) expansion does not write x0"
