from tools.fusion_profile import (
    FUSE_AUIPC_JALR,
    FUSE_LUI_ADDI,
    FUSE_LUI_JALR,
    FUSE_NONE,
    classify_pair,
)


def u_type(opcode_value: int, rd_value: int) -> int:
    return (0x12345 << 12) | (rd_value << 7) | opcode_value


def i_type(opcode_value: int, funct3: int, rs1_value: int, rd_value: int) -> int:
    return (0x12 << 20) | (rs1_value << 15) | (funct3 << 12) | (rd_value << 7) | opcode_value


def test_lui_addi():
    assert classify_pair(u_type(0x37, 5), i_type(0x13, 0, 5, 5)) == FUSE_LUI_ADDI


def test_auipc_jalr():
    assert classify_pair(u_type(0x17, 5), i_type(0x67, 0, 5, 1)) == FUSE_AUIPC_JALR


def test_lui_jalr():
    assert classify_pair(u_type(0x37, 5), i_type(0x67, 0, 5, 1)) == FUSE_LUI_JALR


def test_dependency_and_x0_gates():
    assert classify_pair(u_type(0x37, 5), i_type(0x13, 0, 6, 5)) == FUSE_NONE
    assert classify_pair(u_type(0x37, 0), i_type(0x13, 0, 0, 0)) == FUSE_NONE
    assert classify_pair(u_type(0x37, 5), i_type(0x13, 1, 5, 5)) == FUSE_NONE
