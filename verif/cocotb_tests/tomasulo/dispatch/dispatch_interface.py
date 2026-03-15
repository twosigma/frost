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

"""DUT interface for Dispatch unit verification.

Provides clean access to dispatch signals with proper typing and helper
methods for driving stimulus and reading outputs.

Note: Verilator flattens packed structs into single bit vectors.
This interface handles packing/unpacking struct fields automatically.
"""

from typing import Any

from cocotb.triggers import RisingEdge, FallingEdge

# =============================================================================
# Width constants from riscv_pkg
# =============================================================================
ROB_TAG_WIDTH = 5
XLEN = 32
FLEN = 64
REG_ADDR_WIDTH = 5
CHECKPOINT_ID_WIDTH = 2
RAS_PTR_BITS = 3

MASK_TAG = (1 << ROB_TAG_WIDTH) - 1
MASK32 = (1 << XLEN) - 1
MASK64 = (1 << FLEN) - 1

# instr_op_e: typedef enum (no explicit type) -> 32-bit int in SystemVerilog
OP_WIDTH = 32
MASK_OP = (1 << OP_WIDTH) - 1

# rs_type_e: 3 bits
RS_TYPE_WIDTH = 3

# mem_size_e: 2 bits
MEM_SIZE_WIDTH = 2

# branch_taken_op_e: 3 bits
BRANCH_OP_WIDTH = 3

# store_op_e: 2 bits
STORE_OP_WIDTH = 2

# instr_t: 32 bits packed struct
INSTR_WIDTH = 32

# =============================================================================
# RS type constants
# =============================================================================
RS_INT = 0
RS_MUL = 1
RS_MEM = 2
RS_FP = 3
RS_FMUL = 4
RS_FDIV = 5
RS_NONE = 6

# =============================================================================
# mem_size_e constants
# =============================================================================
MEM_SIZE_BYTE = 0
MEM_SIZE_HALF = 1
MEM_SIZE_WORD = 2
MEM_SIZE_DOUBLE = 3

# =============================================================================
# instr_op_e constants (auto-incrementing from 0)
# =============================================================================
# base-ISA integer ops
ADD = 0
SUB = 1
AND = 2
OR = 3
XOR = 4
SLL = 5
SRL = 6
SRA = 7
SLT = 8
SLTU = 9
ADDI = 10
ANDI = 11
ORI = 12
XORI = 13
SLTI = 14
SLTIU = 15
SLLI = 16
SRLI = 17
SRAI = 18
# upper-imm/jumps
LUI = 19
AUIPC = 20
JAL = 21
JALR = 22
# branches
BEQ = 23
BNE = 24
BLT = 25
BGE = 26
BLTU = 27
BGEU = 28
# loads/stores
LB = 29
LH = 30
LW = 31
LBU = 32
LHU = 33
SB = 34
SH = 35
SW = 36
# M-extension
MUL = 37
MULH = 38
MULHSU = 39
MULHU = 40
DIV = 41
DIVU = 42
REM = 43
REMU = 44
# Zifencei
FENCE = 45
FENCE_I = 46
# Zicsr
CSRRW = 47
CSRRS = 48
CSRRC = 49
CSRRWI = 50
CSRRSI = 51
CSRRCI = 52
# Zba
SH1ADD = 53
SH2ADD = 54
SH3ADD = 55
# Zbs
BSET = 56
BCLR = 57
BINV = 58
BEXT = 59
BSETI = 60
BCLRI = 61
BINVI = 62
BEXTI = 63
# Zbb
ANDN = 64
ORN = 65
XNOR_OP = 66
CLZ = 67
CTZ = 68
CPOP = 69
MAX_OP = 70
MAXU = 71
MIN_OP = 72
MINU = 73
SEXT_B = 74
SEXT_H = 75
ROL = 76
ROR = 77
RORI = 78
ORC_B = 79
REV8 = 80
# Zicond
CZERO_EQZ = 81
CZERO_NEZ = 82
# Zbkb
PACK = 83
PACKH = 84
BREV8 = 85
ZIP = 86
UNZIP = 87
# Zihintpause
PAUSE = 88
# Privileged
MRET = 89
WFI = 90
ECALL = 91
EBREAK = 92
# A extension
LR_W = 93
SC_W = 94
AMOSWAP_W = 95
AMOADD_W = 96
AMOXOR_W = 97
AMOAND_W = 98
AMOOR_W = 99
AMOMIN_W = 100
AMOMAX_W = 101
AMOMINU_W = 102
AMOMAXU_W = 103
# F extension
FLW = 104
FSW = 105
FADD_S = 106
FSUB_S = 107
FMUL_S = 108
FDIV_S = 109
FSQRT_S = 110
FMADD_S = 111
FMSUB_S = 112
FNMADD_S = 113
FNMSUB_S = 114
FSGNJ_S = 115
FSGNJN_S = 116
FSGNJX_S = 117
FMIN_S = 118
FMAX_S = 119
FCVT_W_S = 120
FCVT_WU_S = 121
FCVT_S_W = 122
FCVT_S_WU = 123
FMV_X_W = 124
FMV_W_X = 125
FEQ_S = 126
FLT_S = 127
FLE_S = 128
FCLASS_S = 129
# D extension
FLD = 130
FSD = 131
FADD_D = 132
FSUB_D = 133
FMUL_D = 134
FDIV_D = 135
FSQRT_D = 136
FMADD_D = 137
FMSUB_D = 138
FNMADD_D = 139
FNMSUB_D = 140
FSGNJ_D = 141
FSGNJN_D = 142
FSGNJX_D = 143
FMIN_D = 144
FMAX_D = 145
FCVT_W_D = 146
FCVT_WU_D = 147
FCVT_D_W = 148
FCVT_D_WU = 149
FCVT_S_D = 150
FCVT_D_S = 151
FEQ_D = 152
FLT_D = 153
FLE_D = 154
FCLASS_D = 155


# =============================================================================
# from_id_to_ex_t field table
# =============================================================================
# List of (field_name, bit_width) in declaration order (first = MSB).
# SystemVerilog packed structs place the first-declared field at the highest
# bit positions.  We pack from LSB (last field) to MSB (first field).

FROM_ID_TO_EX_FIELDS = [
    ("program_counter", XLEN),
    ("immediate_i_type", 32),
    ("immediate_s_type", 32),
    ("immediate_b_type", 32),
    ("immediate_u_type", 32),
    ("immediate_j_type", 32),
    ("source_reg_1_data", XLEN),
    ("source_reg_2_data", XLEN),
    ("source_reg_1_is_x0", 1),
    ("source_reg_2_is_x0", 1),
    ("is_load_instruction", 1),
    ("is_load_byte", 1),
    ("is_load_halfword", 1),
    ("is_load_unsigned", 1),
    ("instruction_operation", OP_WIDTH),
    ("branch_operation", BRANCH_OP_WIDTH),
    ("store_operation", STORE_OP_WIDTH),
    ("is_jump_and_link", 1),
    ("is_jump_and_link_register", 1),
    ("is_multiply", 1),
    ("is_divide", 1),
    ("is_csr_instruction", 1),
    ("csr_address", 12),
    ("csr_imm", 5),
    ("is_amo_instruction", 1),
    ("is_lr", 1),
    ("is_sc", 1),
    ("is_mret", 1),
    ("is_wfi", 1),
    ("is_ecall", 1),
    ("is_ebreak", 1),
    ("is_illegal_instruction", 1),
    ("is_fp_instruction", 1),
    ("is_fp_load", 1),
    ("is_fp_store", 1),
    ("is_fp_load_double", 1),
    ("is_fp_store_double", 1),
    ("is_fp_compute", 1),
    ("is_pipelined_fp_op", 1),
    ("fp_rm", 3),
    ("is_fp_to_int", 1),
    ("is_int_to_fp", 1),
    ("fp_source_reg_1_data", FLEN),
    ("fp_source_reg_2_data", FLEN),
    ("fp_source_reg_3_data", FLEN),
    ("link_address", XLEN),
    ("branch_target_precomputed", XLEN),
    ("jal_target_precomputed", XLEN),
    ("instruction", INSTR_WIDTH),
    ("btb_hit", 1),
    ("btb_predicted_taken", 1),
    ("btb_predicted_target", XLEN),
    ("ras_predicted", 1),
    ("ras_predicted_target", XLEN),
    ("ras_checkpoint_tos", RAS_PTR_BITS),
    ("ras_checkpoint_valid_count", RAS_PTR_BITS + 1),
    ("is_ras_return", 1),
    ("is_ras_call", 1),
    ("ras_predicted_target_nonzero", 1),
    ("ras_expected_rs1", XLEN),
    ("btb_correct_non_jalr", 1),
    ("btb_expected_rs1", XLEN),
]

# Compute total width and per-field offsets (bit offset from LSB)
_FROM_ID_TO_EX_TOTAL_WIDTH = sum(w for _, w in FROM_ID_TO_EX_FIELDS)

# Build offset map: field_name -> (bit_offset_from_lsb, width)
_FROM_ID_TO_EX_OFFSETS: dict[str, tuple[int, int]] = {}
_offset = _FROM_ID_TO_EX_TOTAL_WIDTH
for _name, _width in FROM_ID_TO_EX_FIELDS:
    _offset -= _width
    _FROM_ID_TO_EX_OFFSETS[_name] = (_offset, _width)
assert _offset == 0, f"Offset mismatch: {_offset}"


def build_from_id_to_ex(**kwargs: int) -> int:
    """Pack from_id_to_ex_t fields into a single bit vector.

    All fields default to 0.  Pass keyword arguments matching field names
    from the struct definition to set specific fields.
    """
    val = 0
    for name, (offset, width) in _FROM_ID_TO_EX_OFFSETS.items():
        field_val = int(kwargs.get(name, 0))
        mask = (1 << width) - 1
        val |= (field_val & mask) << offset
    return val


def pack_instr_t(
    funct7: int = 0,
    source_reg_2: int = 0,
    source_reg_1: int = 0,
    funct3: int = 0,
    dest_reg: int = 0,
    opcode: int = 0,
) -> int:
    """Pack instr_t (32 bits).

    funct7[31:25] | rs2[24:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0].
    """
    val = 0
    val |= opcode & 0x7F
    val |= (dest_reg & 0x1F) << 7
    val |= (funct3 & 0x7) << 12
    val |= (source_reg_1 & 0x1F) << 15
    val |= (source_reg_2 & 0x1F) << 20
    val |= (funct7 & 0x7F) << 25
    return val


# =============================================================================
# ROB alloc_req_t field table (for unpacking output)
# =============================================================================
# reorder_buffer_alloc_req_t: MSB-first packed struct
ROB_ALLOC_REQ_FIELDS = [
    ("alloc_valid", 1),
    ("pc", XLEN),
    ("dest_rf", 1),
    ("dest_reg", REG_ADDR_WIDTH),
    ("dest_valid", 1),
    ("is_store", 1),
    ("is_fp_store", 1),
    ("is_branch", 1),
    ("predicted_taken", 1),
    ("predicted_target", XLEN),
    ("branch_target", XLEN),
    ("is_call", 1),
    ("is_return", 1),
    ("link_addr", XLEN),
    ("is_jal", 1),
    ("is_jalr", 1),
    ("is_csr", 1),
    ("is_fence", 1),
    ("is_fence_i", 1),
    ("is_wfi", 1),
    ("is_mret", 1),
    ("is_amo", 1),
    ("is_lr", 1),
    ("is_sc", 1),
    ("is_compressed", 1),
    ("csr_addr", 12),
    ("csr_op", 3),
    ("csr_write_data", XLEN),
    ("has_fp_flags", 1),
]

ROB_ALLOC_REQ_WIDTH = sum(w for _, w in ROB_ALLOC_REQ_FIELDS)

_ROB_ALLOC_REQ_OFFSETS: dict[str, tuple[int, int]] = {}
_offset = ROB_ALLOC_REQ_WIDTH
for _name, _width in ROB_ALLOC_REQ_FIELDS:
    _offset -= _width
    _ROB_ALLOC_REQ_OFFSETS[_name] = (_offset, _width)
assert _offset == 0


def unpack_rob_alloc_req(raw: int) -> dict[str, int]:
    """Unpack o_rob_alloc_req bit vector into a dictionary."""
    result: dict[str, int] = {}
    for name, (offset, width) in _ROB_ALLOC_REQ_OFFSETS.items():
        mask = (1 << width) - 1
        result[name] = (raw >> offset) & mask
    return result


# =============================================================================
# ROB alloc_resp_t packing (7 bits input to DUT)
# =============================================================================
# reorder_buffer_alloc_resp_t: {alloc_ready, alloc_tag[4:0], full}
ALLOC_RESP_WIDTH = 7


def pack_rob_alloc_resp(
    alloc_ready: int = 0,
    alloc_tag: int = 0,
    full: int = 0,
) -> int:
    """Pack reorder_buffer_alloc_resp_t (7 bits MSB-first)."""
    val = 0
    val |= full & 1
    val |= (alloc_tag & MASK_TAG) << 1
    val |= (alloc_ready & 1) << 6
    return val


# =============================================================================
# rat_lookup_t packing (70 bits input to DUT)
# =============================================================================
# rat_lookup_t: {renamed[69], tag[68:64], value[63:0]}
RAT_LOOKUP_WIDTH = 70


def pack_rat_lookup(
    renamed: int = 0,
    tag: int = 0,
    value: int = 0,
) -> int:
    """Pack rat_lookup_t (70 bits MSB-first)."""
    val = 0
    val |= value & MASK64
    val |= (tag & MASK_TAG) << FLEN
    val |= (renamed & 1) << (FLEN + ROB_TAG_WIDTH)
    return val


# =============================================================================
# rs_dispatch_t field table (for unpacking output)
# =============================================================================
RS_DISPATCH_FIELDS = [
    ("valid", 1),
    ("rs_type", RS_TYPE_WIDTH),
    ("rob_tag", ROB_TAG_WIDTH),
    ("op", OP_WIDTH),
    ("src1_ready", 1),
    ("src1_tag", ROB_TAG_WIDTH),
    ("src1_value", FLEN),
    ("src2_ready", 1),
    ("src2_tag", ROB_TAG_WIDTH),
    ("src2_value", FLEN),
    ("src3_ready", 1),
    ("src3_tag", ROB_TAG_WIDTH),
    ("src3_value", FLEN),
    ("imm", XLEN),
    ("use_imm", 1),
    ("rm", 3),
    ("branch_target", XLEN),
    ("predicted_taken", 1),
    ("predicted_target", XLEN),
    ("is_fp_mem", 1),
    ("mem_size", MEM_SIZE_WIDTH),
    ("mem_signed", 1),
    ("csr_addr", 12),
    ("csr_imm", 5),
    ("pc", XLEN),
    ("link_addr", XLEN),
]

RS_DISPATCH_WIDTH = sum(w for _, w in RS_DISPATCH_FIELDS)

_RS_DISPATCH_OFFSETS: dict[str, tuple[int, int]] = {}
_offset = RS_DISPATCH_WIDTH
for _name, _width in RS_DISPATCH_FIELDS:
    _offset -= _width
    _RS_DISPATCH_OFFSETS[_name] = (_offset, _width)
assert _offset == 0


def unpack_rs_dispatch(raw: int) -> dict[str, int]:
    """Unpack o_rs_dispatch bit vector into a dictionary."""
    result: dict[str, int] = {}
    for name, (offset, width) in _RS_DISPATCH_OFFSETS.items():
        mask = (1 << width) - 1
        result[name] = (raw >> offset) & mask
    return result


# =============================================================================
# DUT Interface Class
# =============================================================================


class DispatchInterface:
    """Interface to the Dispatch DUT.

    Handles packing/unpacking of struct signals automatically since
    Verilator flattens packed structs into single bit vectors.
    """

    def __init__(self, dut: Any) -> None:
        """Initialize interface with DUT handle."""
        self.dut = dut

    @property
    def clock(self) -> Any:
        """Return clock signal."""
        return self.dut.i_clk

    async def reset_dut(self, cycles: int = 5) -> None:
        """Reset the DUT and initialize all inputs.

        After reset, returns at falling edge so signals driven immediately
        after reset are stable before the next rising edge.
        """
        self._init_inputs()
        self.dut.i_rst_n.value = 0

        for _ in range(cycles):
            await RisingEdge(self.clock)

        self.dut.i_rst_n.value = 1
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    async def step(self) -> None:
        """Advance one cycle: rising edge then falling edge."""
        await RisingEdge(self.clock)
        await FallingEdge(self.clock)

    def _init_inputs(self) -> None:
        """Initialize all input signals to safe defaults."""
        self.dut.i_from_id_to_ex.value = 0
        self.dut.i_valid.value = 0
        self.dut.i_rs1_addr.value = 0
        self.dut.i_rs2_addr.value = 0
        self.dut.i_fp_rs3_addr.value = 0
        self.dut.i_frm_csr.value = 0
        self.dut.i_rob_alloc_resp.value = 0
        self.dut.i_int_src1.value = 0
        self.dut.i_int_src2.value = 0
        self.dut.i_fp_src1.value = 0
        self.dut.i_fp_src2.value = 0
        self.dut.i_fp_src3.value = 0
        self.dut.i_checkpoint_available.value = 0
        self.dut.i_checkpoint_alloc_id.value = 0
        self.dut.i_ras_tos.value = 0
        self.dut.i_ras_valid_count.value = 0
        self.dut.i_rob_full.value = 0
        self.dut.i_int_rs_full.value = 0
        self.dut.i_mul_rs_full.value = 0
        self.dut.i_mem_rs_full.value = 0
        self.dut.i_fp_rs_full.value = 0
        self.dut.i_fmul_rs_full.value = 0
        self.dut.i_fdiv_rs_full.value = 0
        self.dut.i_lq_full.value = 0
        self.dut.i_sq_full.value = 0
        self.dut.i_flush.value = 0

    # =========================================================================
    # Instruction Input
    # =========================================================================

    def drive_instruction(
        self,
        valid: bool = True,
        rs1_addr: int = 0,
        rs2_addr: int = 0,
        fp_rs3_addr: int = 0,
        **kwargs: int,
    ) -> None:
        """Drive the instruction input and associated signals.

        ``kwargs`` are passed to ``build_from_id_to_ex`` to pack the
        ``i_from_id_to_ex`` bitvector.
        """
        self.dut.i_valid.value = 1 if valid else 0
        self.dut.i_rs1_addr.value = rs1_addr & 0x1F
        self.dut.i_rs2_addr.value = rs2_addr & 0x1F
        self.dut.i_fp_rs3_addr.value = fp_rs3_addr & 0x1F
        self.dut.i_from_id_to_ex.value = build_from_id_to_ex(**kwargs)

    def clear_instruction(self) -> None:
        """De-assert instruction valid and zero out inputs."""
        self.dut.i_valid.value = 0
        self.dut.i_from_id_to_ex.value = 0

    # =========================================================================
    # FRM CSR
    # =========================================================================

    def set_frm_csr(self, frm: int) -> None:
        """Set the FRM CSR value."""
        self.dut.i_frm_csr.value = frm & 0x7

    # =========================================================================
    # ROB Allocation Response
    # =========================================================================

    def drive_rob_alloc_resp(
        self, alloc_ready: int = 1, alloc_tag: int = 0, full: int = 0
    ) -> None:
        """Drive the ROB allocation response input."""
        self.dut.i_rob_alloc_resp.value = pack_rob_alloc_resp(
            alloc_ready=alloc_ready, alloc_tag=alloc_tag, full=full
        )

    # =========================================================================
    # RAT Source Lookups
    # =========================================================================

    def drive_int_src1(self, renamed: int = 0, tag: int = 0, value: int = 0) -> None:
        """Drive integer source 1 RAT lookup result."""
        self.dut.i_int_src1.value = pack_rat_lookup(renamed, tag, value)

    def drive_int_src2(self, renamed: int = 0, tag: int = 0, value: int = 0) -> None:
        """Drive integer source 2 RAT lookup result."""
        self.dut.i_int_src2.value = pack_rat_lookup(renamed, tag, value)

    def drive_fp_src1(self, renamed: int = 0, tag: int = 0, value: int = 0) -> None:
        """Drive FP source 1 RAT lookup result."""
        self.dut.i_fp_src1.value = pack_rat_lookup(renamed, tag, value)

    def drive_fp_src2(self, renamed: int = 0, tag: int = 0, value: int = 0) -> None:
        """Drive FP source 2 RAT lookup result."""
        self.dut.i_fp_src2.value = pack_rat_lookup(renamed, tag, value)

    def drive_fp_src3(self, renamed: int = 0, tag: int = 0, value: int = 0) -> None:
        """Drive FP source 3 RAT lookup result."""
        self.dut.i_fp_src3.value = pack_rat_lookup(renamed, tag, value)

    # =========================================================================
    # Resource Status
    # =========================================================================

    def set_rob_full(self, full: bool) -> None:
        """Set ROB full signal."""
        self.dut.i_rob_full.value = 1 if full else 0

    def set_int_rs_full(self, full: bool) -> None:
        """Set INT RS full signal."""
        self.dut.i_int_rs_full.value = 1 if full else 0

    def set_mul_rs_full(self, full: bool) -> None:
        """Set MUL RS full signal."""
        self.dut.i_mul_rs_full.value = 1 if full else 0

    def set_mem_rs_full(self, full: bool) -> None:
        """Set MEM RS full signal."""
        self.dut.i_mem_rs_full.value = 1 if full else 0

    def set_fp_rs_full(self, full: bool) -> None:
        """Set FP RS full signal."""
        self.dut.i_fp_rs_full.value = 1 if full else 0

    def set_fmul_rs_full(self, full: bool) -> None:
        """Set FMUL RS full signal."""
        self.dut.i_fmul_rs_full.value = 1 if full else 0

    def set_fdiv_rs_full(self, full: bool) -> None:
        """Set FDIV RS full signal."""
        self.dut.i_fdiv_rs_full.value = 1 if full else 0

    def set_lq_full(self, full: bool) -> None:
        """Set LQ full signal."""
        self.dut.i_lq_full.value = 1 if full else 0

    def set_sq_full(self, full: bool) -> None:
        """Set SQ full signal."""
        self.dut.i_sq_full.value = 1 if full else 0

    # =========================================================================
    # Checkpoint
    # =========================================================================

    def drive_checkpoint(self, available: bool = True, alloc_id: int = 0) -> None:
        """Drive checkpoint availability and allocation ID."""
        self.dut.i_checkpoint_available.value = 1 if available else 0
        self.dut.i_checkpoint_alloc_id.value = alloc_id & (
            (1 << CHECKPOINT_ID_WIDTH) - 1
        )

    # =========================================================================
    # RAS State
    # =========================================================================

    def drive_ras(self, tos: int = 0, valid_count: int = 0) -> None:
        """Drive RAS top-of-stack and valid count inputs."""
        self.dut.i_ras_tos.value = tos & ((1 << RAS_PTR_BITS) - 1)
        self.dut.i_ras_valid_count.value = valid_count & ((1 << (RAS_PTR_BITS + 1)) - 1)

    # =========================================================================
    # Flush
    # =========================================================================

    def set_flush(self, flush: bool) -> None:
        """Set flush signal."""
        self.dut.i_flush.value = 1 if flush else 0

    # =========================================================================
    # Output Readers
    # =========================================================================

    def read_rob_alloc_req(self) -> dict[str, int]:
        """Read and unpack o_rob_alloc_req."""
        return unpack_rob_alloc_req(int(self.dut.o_rob_alloc_req.value))

    def read_rs_dispatch(self) -> dict[str, int]:
        """Read and unpack o_rs_dispatch."""
        return unpack_rs_dispatch(int(self.dut.o_rs_dispatch.value))

    @property
    def stall(self) -> bool:
        """Read o_stall output."""
        return bool(self.dut.o_stall.value)

    @property
    def rat_alloc_valid(self) -> bool:
        """Read o_rat_alloc_valid output."""
        return bool(self.dut.o_rat_alloc_valid.value)

    @property
    def rat_alloc_dest_rf(self) -> int:
        """Read o_rat_alloc_dest_rf output (0=INT, 1=FP)."""
        return int(self.dut.o_rat_alloc_dest_rf.value)

    @property
    def rat_alloc_dest_reg(self) -> int:
        """Read o_rat_alloc_dest_reg output."""
        return int(self.dut.o_rat_alloc_dest_reg.value)

    @property
    def rat_alloc_rob_tag(self) -> int:
        """Read o_rat_alloc_rob_tag output."""
        return int(self.dut.o_rat_alloc_rob_tag.value)

    @property
    def checkpoint_save(self) -> bool:
        """Read o_checkpoint_save output."""
        return bool(self.dut.o_checkpoint_save.value)

    @property
    def checkpoint_id(self) -> int:
        """Read o_checkpoint_id output."""
        return int(self.dut.o_checkpoint_id.value)

    @property
    def checkpoint_branch_tag(self) -> int:
        """Read o_checkpoint_branch_tag output."""
        return int(self.dut.o_checkpoint_branch_tag.value)

    @property
    def rob_checkpoint_valid(self) -> bool:
        """Read o_rob_checkpoint_valid output."""
        return bool(self.dut.o_rob_checkpoint_valid.value)

    @property
    def rob_checkpoint_id(self) -> int:
        """Read o_rob_checkpoint_id output."""
        return int(self.dut.o_rob_checkpoint_id.value)

    @property
    def ras_tos_out(self) -> int:
        """Read o_ras_tos output."""
        return int(self.dut.o_ras_tos.value)

    @property
    def ras_valid_count_out(self) -> int:
        """Read o_ras_valid_count output."""
        return int(self.dut.o_ras_valid_count.value)
