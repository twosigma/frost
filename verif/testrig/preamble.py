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

"""Instructions FROST runs after each reset, before a TestRIG test.

TestRIG expects every test to start like a freshly reset Sail model: x1-x31
and f0-f31 zero, the CSRs at Sail's reset values, M-mode, and the PC at
0x8000_0000. FROST resets its CSRs but not its register files, and a few of
its CSR reset values differ from Sail's (mstatus.FS, the counter-enables,
stimecmp). So the harness injects this preamble at FROST's reset PC, 0, ahead
of each test and drops its records. It ends with a jump that lays its last
two instructions out just below 0x8000_0000, so the test's first instruction
lands there, and its last instruction zeroes minstret, so the test reads the
same instruction count as Sail.
"""

TEST_START_PC = 0x8000_0000

# CSR addresses.
CSR_FCSR = 0x003
CSR_SCOUNTEREN = 0x106
CSR_STIMECMP = 0x14D
CSR_MSTATUS = 0x300
CSR_MCOUNTEREN = 0x306
CSR_MINSTRET = 0xB02

# The register the preamble jumps through, zeroed after the jump.
_SCRATCH = 31


def _i_type(opcode: int, funct3: int, rd: int, rs1: int, imm: int) -> int:
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def _addi(rd: int, rs1: int, imm: int) -> int:
    return _i_type(0x13, 0b000, rd, rs1, imm)


def _slli(rd: int, rs1: int, shamt: int) -> int:
    return _i_type(0x13, 0b001, rd, rs1, shamt)


def _srli(rd: int, rs1: int, shamt: int) -> int:
    return _i_type(0x13, 0b101, rd, rs1, shamt)


def _lui(rd: int, imm20: int) -> int:
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37


def _jalr(rd: int, rs1: int, imm: int) -> int:
    return _i_type(0x67, 0b000, rd, rs1, imm)


def _csrw(csr: int, rs1: int) -> int:
    """Encode csrrw x0, csr, rs1."""
    return _i_type(0x73, 0b001, 0, rs1, csr)


def _fmv_d_x(fd: int, rs1: int) -> int:
    return (0b1111001 << 25) | (rs1 << 15) | (fd << 7) | 0x53


def reset_preamble() -> list[int]:
    """Return the preamble's instruction words, in execution order."""
    words = [_addi(rd, 0, 0) for rd in range(1, _SCRATCH)]
    # FROST resets mstatus.FS to Initial, so FP writes are legal here.
    words += [_fmv_d_x(fd, 0) for fd in range(32)]
    words += [
        _csrw(CSR_FCSR, 0),
        _csrw(CSR_MCOUNTEREN, 0),
        _csrw(CSR_SCOUNTEREN, 0),
        _csrw(CSR_STIMECMP, 0),
        # Sail resets FS to Off (and MPP to U, as FROST does).
        _csrw(CSR_MSTATUS, 0),
    ]
    tail = [_addi(_SCRATCH, 0, 0), _csrw(CSR_MINSTRET, 0)]
    landing = TEST_START_PC - 4 * len(tail)
    # x31 = landing: lui sign-extends, so clear the upper half first.
    words += [
        _lui(_SCRATCH, TEST_START_PC >> 12),
        _slli(_SCRATCH, _SCRATCH, 32),
        _srli(_SCRATCH, _SCRATCH, 32),
        _addi(_SCRATCH, _SCRATCH, landing - TEST_START_PC),
        _jalr(0, _SCRATCH, 0),
    ]
    return words + tail
