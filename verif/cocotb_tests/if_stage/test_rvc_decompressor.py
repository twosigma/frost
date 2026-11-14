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

import importlib.util
from pathlib import Path
from types import ModuleType
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
OPC_OP_IMM_32 = 0b0011011
OPC_OP_32 = 0b0111011


def _load_predecode_generator() -> ModuleType:
    """Import the independent offline IMEM-sideband model."""
    path = (
        Path(__file__).resolve().parents[3]
        / "sw"
        / "common"
        / "generate_imem_predecode_init.py"
    )
    spec = importlib.util.spec_from_file_location("generate_imem_predecode_init", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_PREDECODE = _load_predecode_generator()


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


def _imm_ld_sd(raw: int) -> int:
    """Decode the C.LD/C.SD (and C.FLD/C.FSD) 8-scaled immediate."""
    return (((raw >> 5) & 0x3) << 6) | (((raw >> 10) & 0x7) << 3)


def _imm_ldsp(raw: int) -> int:
    """Decode the C.LDSP (and C.FLDSP) 8-scaled immediate."""
    return (
        (((raw >> 2) & 0x7) << 6)
        | (((raw >> 12) & 0x1) << 5)
        | (((raw >> 5) & 0x3) << 3)
    )


def _imm_sdsp(raw: int) -> int:
    """Decode the C.SDSP (and C.FSDSP) 8-scaled immediate."""
    return (((raw >> 7) & 0x7) << 6) | (((raw >> 10) & 0x7) << 3)


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
async def test_all_rvc_source_metadata_matches_decompressor(dut: Any) -> None:
    """All RVC parcels match the predecode model's expansion and source bits."""
    for raw in range(1 << 16):
        if raw & 0x3 == 0x3:
            continue

        _drive(dut, raw)
        await _settle()

        expanded = int(dut.o_instr_expanded.value)
        assert (expanded, bool(int(dut.o_illegal.value))) == _PREDECODE.rvc_expand(
            raw
        ), f"expanded sideband: RVC 0x{raw:04x}"
        got = (((expanded >> 21) & 1) << 2) | ((expanded >> 16) & 0x3)
        rs1_rest = ((expanded >> 17) & 0x6) | ((expanded >> 15) & 1)
        assert rs1_rest == _PREDECODE.rvc_rs1_rest(raw), (
            f"rs1 sideband: RVC 0x{raw:04x}"
        )
        expected = _PREDECODE.rvc_source_hot(raw)
        assert got == expected, (
            f"RVC 0x{raw:04x}: decompressor source-hot 0b{got:03b}, "
            f"sideband model 0b{expected:03b}"
        )


@cocotb.test()
async def test_all_rvc_bits24_20_metadata_matches_decompressor(dut: Any) -> None:
    """All RVC parcels produce the sideband's exact expanded bits [24:20]."""
    for raw in range(1 << 16):
        if raw & 0x3 == 0x3:
            continue

        _drive(dut, raw)
        await _settle()

        got = (int(dut.o_instr_expanded.value) >> 20) & 0x1F
        expected = _PREDECODE.rvc_bits24_20(raw)
        assert got == expected, (
            f"RVC 0x{raw:04x}: decompressor bits[24:20] 0b{got:05b}, "
            f"sideband model 0b{expected:05b}"
        )


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
        # C.LUI rd!=0 with imm==0 and C.ADDI16SP with imm==0 are reserved.
        # C.LUI rd=0 with imm!=0 is a HINT, not illegal; see
        # test_rvc_rd0_hints_are_legal_nops.
        _pack_compressed(funct3=0b011, quadrant=0b01, bits12_2=(10 << 5)),
        _pack_compressed(funct3=0b011, quadrant=0b01, bits12_2=(2 << 5)),
    ):
        _drive(dut, illegal_raw)
        await _settle()

        assert bool(dut.o_illegal.value) is True


@cocotb.test()
async def test_quadrant1_alu_group_expands_all_ops(
    dut: Any,
) -> None:
    """Quadrant-1 ALU group expands the shared ops and the RV64 bit12=1 W-forms."""
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

    bit12_raw = sub_raw | (1 << 12)
    _drive(dut, bit12_raw)
    await _settle()

    # The RV32-reserved bit12=1 slot is C.SUBW on RV64.
    _assert_decode(
        dut,
        expanded=_pack_r(
            funct7=0b0100000,
            rs2=_rs2_prime(bit12_raw),
            rs1=_rs1_prime(bit12_raw),
            funct3=0b000,
            rd=_rs1_prime(bit12_raw),
            opcode=OPC_OP_32,
        ),
    )


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
    """C.SLLI bit12 decodes as shamt[5]; C.LWSP rd=x0 is reserved.

    C.SLLI bit12=1 is legal on RV64 and designated for custom extensions
    on RV32. C.SLLI rd=x0 is a HINT, not illegal.
    """
    slli_bit12_raw = _pack_compressed(
        funct3=0b000, quadrant=0b10, bits12_2=(1 << 10) | (3 << 5)
    )
    _drive(dut, slli_bit12_raw)
    await _settle()
    _assert_decode(
        dut,
        expanded=_pack_i(imm=0b100000, rs1=3, funct3=0b001, rd=3, opcode=OPC_OP_IMM),
    )

    lwsp_rd0_raw = _pack_compressed(funct3=0b010, quadrant=0b10, bits12_2=0b00101)
    _drive(dut, lwsp_rd0_raw)
    await _settle()
    assert bool(dut.o_illegal.value) is True


@cocotb.test()
async def test_rvc_rd0_hints_are_legal_nops(dut: Any) -> None:
    """rd=x0 forms of C.ADD/C.MV/C.LUI/C.SLLI are HINTs that execute as NOPs.

    They expand to a write of x0 and must not be flagged illegal.
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
        assert bool(dut.o_illegal.value) is False, (
            f"{name} ({raw:#06x}) flagged illegal"
        )
        # Expanded instruction must target x0 (rd = bits[11:7]) -> nop.
        assert ((int(dut.o_instr_expanded.value) >> 7) & 0x1F) == 0, (
            f"{name} ({raw:#06x}) expansion does not write x0"
        )


# ============================================================================
# RV64C: the slots that RV64 reinterprets expand to their RV64 meanings. These
# directed vectors check against hand-packed encodings, independent of the
# offline predecode model used above.
# ============================================================================
@cocotb.test()
async def test_rv64_c_addiw_expands_and_rd0_is_reserved(dut: Any) -> None:
    """RV32 C.JAL slot is C.ADDIW on RV64; rd=x0 is reserved."""
    addiw_raw = _pack_compressed(
        funct3=0b001, quadrant=0b01, bits12_2=(1 << 10) | (7 << 5) | 0b10110
    )
    _drive(dut, addiw_raw)
    await _settle()
    imm = _sign_extend((1 << 5) | 0b10110, 6)
    _assert_decode(
        dut,
        expanded=_pack_i(imm=imm, rs1=7, funct3=0b000, rd=7, opcode=OPC_OP_IMM_32),
    )

    rd0_raw = _pack_compressed(funct3=0b001, quadrant=0b01, bits12_2=0b00100)
    _drive(dut, rd0_raw)
    await _settle()
    assert bool(dut.o_illegal.value) is True


@cocotb.test()
async def test_rv64_c_ld_and_c_sd_expand_as_integer_8_scaled(dut: Any) -> None:
    """RV32 C.FLW/C.FSW slots are C.LD/C.SD on RV64 (integer, 8-scaled)."""
    ld_raw = _pack_compressed(
        funct3=0b011,
        quadrant=0b00,
        bits12_2=(0b101 << 8) | (2 << 5) | (1 << 4) | (1 << 3) | 4,
    )
    _drive(dut, ld_raw)
    await _settle()
    _assert_decode(
        dut,
        expanded=_pack_i(
            imm=_imm_ld_sd(ld_raw),
            rs1=_rs1_prime(ld_raw),
            funct3=0b011,
            rd=_rd_prime(ld_raw),
            opcode=OPC_LOAD,
        ),
    )

    sd_raw = _pack_compressed(
        funct3=0b111,
        quadrant=0b00,
        bits12_2=(0b011 << 8) | (5 << 5) | (1 << 4) | (0 << 3) | 6,
    )
    _drive(dut, sd_raw)
    await _settle()
    _assert_decode(
        dut,
        expanded=_pack_s(
            imm=_imm_ld_sd(sd_raw),
            rs2=_rs2_prime(sd_raw),
            rs1=_rs1_prime(sd_raw),
            funct3=0b011,
            opcode=OPC_STORE,
        ),
    )


@cocotb.test()
async def test_rv64_c_ldsp_and_c_sdsp_expand_and_ldsp_rd0_reserved(dut: Any) -> None:
    """RV32 C.FLWSP/C.FSWSP slots are C.LDSP (rd!=0) / C.SDSP on RV64."""
    ldsp_raw = _pack_compressed(
        funct3=0b011, quadrant=0b10, bits12_2=(1 << 10) | (11 << 5) | 0b10110
    )
    _drive(dut, ldsp_raw)
    await _settle()
    _assert_decode(
        dut,
        expanded=_pack_i(
            imm=_imm_ldsp(ldsp_raw), rs1=2, funct3=0b011, rd=11, opcode=OPC_LOAD
        ),
    )

    ldsp_rd0_raw = _pack_compressed(funct3=0b011, quadrant=0b10, bits12_2=0b00101)
    _drive(dut, ldsp_rd0_raw)
    await _settle()
    assert bool(dut.o_illegal.value) is True

    sdsp_raw = _pack_compressed(
        funct3=0b111, quadrant=0b10, bits12_2=(0b101001 << 5) | 13
    )
    _drive(dut, sdsp_raw)
    await _settle()
    _assert_decode(
        dut,
        expanded=_pack_s(
            imm=_imm_sdsp(sdsp_raw), rs2=13, rs1=2, funct3=0b011, opcode=OPC_STORE
        ),
    )


@cocotb.test()
async def test_rv64_c_addw_expands_and_upper_subops_stay_reserved(dut: Any) -> None:
    """bit12=1 [6:5]=01 is C.ADDW; Zcb takes [6:5]=10 (C.MUL) and 11 ([4:2]<=101)."""
    addw_raw = _pack_compressed(
        funct3=0b100,
        quadrant=0b01,
        bits12_2=(1 << 10) | (0b11 << 8) | (3 << 5) | (0b01 << 3) | 4,
    )
    _drive(dut, addw_raw)
    await _settle()
    _assert_decode(
        dut,
        expanded=_pack_r(
            funct7=0b0000000,
            rs2=_rs2_prime(addw_raw),
            rs1=_rs1_prime(addw_raw),
            funct3=0b000,
            rd=_rs1_prime(addw_raw),
            opcode=OPC_OP_32,
        ),
    )

    for sel in (0b110, 0b111):
        reserved_raw = _pack_compressed(
            funct3=0b100,
            quadrant=0b01,
            bits12_2=(1 << 10) | (0b11 << 8) | (3 << 5) | (0b11 << 3) | sel,
        )
        _drive(dut, reserved_raw)
        await _settle()
        assert int(dut.o_instr_expanded.value) == 0
        assert bool(dut.o_illegal.value) is True


# Zcb vectors: parcels and expansions assembled by GNU as 2.42
# (-march=rv64gc_zba_zbb_zcb), independent of the predecode model.
_ZCB_VECTORS = (
    # (raw parcel, expansion, name)
    (0x8000, 0x00044403, "c.lbu s0, 0(s0)"),
    (0x80E4, 0x0034C483, "c.lbu s1, 3(s1)"),
    (0x8484, 0x0004D483, "c.lhu s1, 0(s1)"),
    (0x84E4, 0x00249483, "c.lh s1, 2(s1)"),
    (0x88C4, 0x009480A3, "c.sb s1, 1(s1)"),
    (0x8C84, 0x00949023, "c.sh s1, 0(s1)"),
    (0x8CA4, 0x00949123, "c.sh s1, 2(s1)"),
    (0x9C61, 0x0FF47413, "c.zext.b s0"),
    (0x9CE5, 0x60449493, "c.sext.b s1"),
    (0x9FE9, 0x0807C7BB, "c.zext.h a5"),
    (0x9FED, 0x60579793, "c.sext.h a5"),
    (0x9FF1, 0x080787BB, "c.zext.w a5"),
    (0x9FF5, 0xFFF7C793, "c.not a5"),
    (0x9CC5, 0x029484B3, "c.mul s1, s1, s1"),
)

# C.MOP.n (n odd, 1-15) is C.LUI xn, 0 and writes no register.
_ZCMOP_VECTORS = tuple((0x6001 | (n << 7), f"c.mop.{n}") for n in range(1, 16, 2))

# Reserved neighbours of the new encodings, which stay illegal.
_ZCB_RESERVED = (
    (0x8CC4, "c.sh slot with bit 6 set"),
    (0x9000, "quadrant-0 funct3=100 bit 12"),
    (0x9C00, "quadrant-0 funct3=100 [12:10]=111"),
    (0x6001, "c.lui x0, 0"),
    (0x6201, "c.lui x4, 0"),
    (0x6801, "c.lui x16, 0"),
    (0x6881, "c.lui x17, 0"),
    (0x9C79, "zcb unary selector 110"),
    (0x9C7D, "zcb unary selector 111"),
)


@cocotb.test()
async def test_zcb_forms_expand_to_their_base_equivalents(dut: Any) -> None:
    """Every Zcb form expands to the base or Zba/Zbb/M instruction the spec names."""
    for raw, expanded, name in _ZCB_VECTORS:
        _drive(dut, raw)
        await _settle()
        got = int(dut.o_instr_expanded.value)
        assert got == expanded, f"{name} ({raw:#06x}): {got:#010x} != {expanded:#010x}"
        assert bool(dut.o_illegal.value) is False, name
        assert _PREDECODE.rvc_expand(raw) == (expanded, False), name


@cocotb.test()
async def test_zcmop_forms_expand_to_nop_and_neighbours_stay_reserved(dut: Any) -> None:
    """C.MOP.n expands to the canonical NOP; reserved neighbours stay illegal."""
    for raw, name in _ZCMOP_VECTORS:
        _drive(dut, raw)
        await _settle()
        assert int(dut.o_instr_expanded.value) == 0x00000013, name
        assert bool(dut.o_illegal.value) is False, name
    for raw, name in _ZCB_RESERVED:
        _drive(dut, raw)
        await _settle()
        assert bool(dut.o_illegal.value) is True, f"{name} ({raw:#06x})"
        assert _PREDECODE.rvc_expand(raw)[1] is True, name


@cocotb.test()
async def test_zihintntl_c_ntl_forms_are_legal_add_x0_hints(dut: Any) -> None:
    """C.NTL.P1/PALL/S1/ALL are c.add x0, x2..x5: legal hints writing x0."""
    for rs2, name in (
        (2, "c.ntl.p1"),
        (3, "c.ntl.pall"),
        (4, "c.ntl.s1"),
        (5, "c.ntl.all"),
    ):
        raw = 0x9002 | (rs2 << 2)
        _drive(dut, raw)
        await _settle()
        assert int(dut.o_instr_expanded.value) == (rs2 << 20) | 0x33, name
        assert bool(dut.o_illegal.value) is False, name


@cocotb.test()
async def test_rv64_shift_shamt6_carries_bit12(dut: Any) -> None:
    """C.SRLI/C.SRAI take 6-bit shamts on RV64 with bit 12 as shamt[5]."""
    srli_raw = _pack_compressed(
        funct3=0b100,
        quadrant=0b01,
        bits12_2=(1 << 10) | (0b00 << 8) | (5 << 5) | 0b00011,
    )
    _drive(dut, srli_raw)
    await _settle()
    _assert_decode(
        dut,
        expanded=_pack_i(
            imm=0b100011,
            rs1=_rs1_prime(srli_raw),
            funct3=0b101,
            rd=_rs1_prime(srli_raw),
            opcode=OPC_OP_IMM,
        ),
    )

    srai_raw = _pack_compressed(
        funct3=0b100,
        quadrant=0b01,
        bits12_2=(1 << 10) | (0b01 << 8) | (5 << 5) | 0b00011,
    )
    _drive(dut, srai_raw)
    await _settle()
    _assert_decode(
        dut,
        expanded=_pack_i(
            imm=(0b010000 << 6) | 0b100011,
            rs1=_rs1_prime(srai_raw),
            funct3=0b101,
            rd=_rs1_prime(srai_raw),
            opcode=OPC_OP_IMM,
        ),
    )
