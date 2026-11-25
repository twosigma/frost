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

"""Debug Mode partial loads, mid-run halts with vstart, and vector single-stepping."""

from typing import Any

import cocotb
from cocotb.utils import get_sim_time

from cocotb_tests.debug.jtag_dtm import (
    CMDERR_EXCEPTION,
    CSR_DCSR,
    CSR_DPC,
    CSR_MSTATUS,
    DCSR_CAUSE_EBREAK,
    DCSR_CAUSE_HALTREQ,
    DCSR_CAUSE_MASK,
    DCSR_CAUSE_SHIFT,
    DCSR_CAUSE_STEP,
    DCSR_EBREAKM,
    DCSR_STEP,
    DM_DMCONTROL,
    DMCONTROL_DMACTIVE,
    DMCONTROL_HALTREQ,
    DMCONTROL_RESUMEREQ,
    DMSTATUS_ALLHALTED,
    INSN_EBREAK,
    INSN_FENCE,
    INSN_NOP,
    DebugModule,
    Dtm,
    JtagDriver,
    addi,
    csrr,
    csrw,
    load,
    store,
)
from cocotb_tests.debug.test_debug import _reset
from cocotb_tests.test_real_program import (
    CLK_PERIOD_NS,
    generate_divided_clock,
    start_clocks,
    start_cpu_clock,
    takes_last_edge,
)


# The partial load writes v8 before its page fault, which re-parks the hart in
# Debug Mode without an M/S trap. The head unit reports the register write
# itself, so mstatus.VS must read Dirty afterwards.
@cocotb.test()
@takes_last_edge
async def test_partial_load_dirties_vs(dut: Any) -> None:
    """A valid first page writes v8 before an invalid second page re-parks."""
    start_clocks((dut.i_clk,), CLK_PERIOD_NS * 1000)
    start_cpu_clock(dut)
    cocotb.start_soon(generate_divided_clock(dut))
    await _reset(dut)
    jtag = JtagDriver(dut, half_period=4)
    await jtag.reset()
    dm = DebugModule(Dtm(jtag, idle_cycles=1), cocotb.log)
    await dm.activate()
    await dm.halt()
    root, l1, l0, frame, dump = (
        0x83500000,
        0x83501000,
        0x83502000,
        0x83503000,
        0x83504000,
    )
    for address, value in (
        (root, ((l1 >> 12) << 10) | 1),
        (l1 + 16, ((l0 >> 12) << 10) | 1),
        (l0, ((frame >> 12) << 10) | 0xC7),
        (l0 + 8, 0),
        (frame + 4088, 0x8877665544332211),
        (dump, 0),
        (dump + 8, 0),
    ):
        await dm.write_mem(address, 8, value)
    await dm.write_csr(0x300, (await dm.read_csr(0x300)) | (3 << 9))
    # vsetivli x0,4,e32,m1,tu,mu; vle32.v v8,(s0)
    await dm.exec_progbuf([0xC1027057])
    await dm.write_gpr(dm.S0, dump)
    vle32 = (1 << 25) | (dm.S0 << 15) | (6 << 12) | (8 << 7) | 0x07
    await dm.exec_progbuf([vle32])
    await dm.write_csr(0x180, (8 << 60) | (root >> 12))
    await dm.exec_progbuf([0x12000073])  # sfence.vma
    await dm.write_gpr(dm.S0, 0x00400FF8)
    saved = await dm.read_csr(0x300)
    clean = (saved & ~((3 << 11) | (3 << 9))) | (1 << 11) | (1 << 17) | (2 << 9)
    await dm.write_csr(0x300, clean)
    await dm.exec_progbuf([vle32], expect=CMDERR_EXCEPTION)
    await dm.clear_cmderr()
    status = await dm.read_csr(0x300)
    vstart = await dm.read_csr(0x008)
    # Record VS before the dump store or any explicit vector CSR write.
    await dm.write_csr(0x300, status & ~(1 << 17))
    await dm.write_csr(0x180, 0)
    await dm.write_gpr(dm.S0, dump)
    vs1r = (1 << 25) | (8 << 20) | (dm.S0 << 15) | (8 << 7) | 0x27
    await dm.exec_progbuf([vs1r])
    low = await dm.read_mem(dump, 8)
    high = await dm.read_mem(dump + 8, 8)
    assert low == 0x8877665544332211 and high == 0, (hex(low), hex(high))
    cocotb.log.info(
        "Debug partial load wrote v8: VS=%d vstart=%d", (status >> 9) & 3, vstart
    )
    assert (status >> 9) & 3 == 3, (
        "partial load changed v8 but left mstatus.VS non-Dirty"
    )

    # A strided load: element 0 at 0x400ff8 is performed at the head, element
    # 1 at 0x401000 faults. VS must read Dirty again.
    await dm.write_mem(frame + 4088, 8, 0x0123456789ABCDEF)
    await dm.write_csr(0x180, (8 << 60) | (root >> 12))
    await dm.exec_progbuf([0x12000073])  # sfence.vma
    await dm.write_gpr(dm.S0, 0x00400FF8)
    await dm.write_gpr(dm.S1, 8)
    saved = await dm.read_csr(0x300)
    clean = (saved & ~((3 << 11) | (3 << 9))) | (1 << 11) | (1 << 17) | (2 << 9)
    await dm.write_csr(0x300, clean)
    # vlse32.v v8, (s0), s1
    vlse32 = (
        (2 << 26)
        | (1 << 25)
        | (dm.S1 << 20)
        | (dm.S0 << 15)
        | (6 << 12)
        | (8 << 7)
        | 0x07
    )
    await dm.exec_progbuf([vlse32], expect=CMDERR_EXCEPTION)
    await dm.clear_cmderr()
    status = await dm.read_csr(0x300)
    await dm.write_csr(0x300, status & ~(1 << 17))
    await dm.write_csr(0x180, 0)
    await dm.write_gpr(dm.S0, dump)
    await dm.exec_progbuf([vs1r])
    low = await dm.read_mem(dump, 8)
    high = await dm.read_mem(dump + 8, 8)
    # Element 0 is the frame's word; element 1 keeps the earlier load's value.
    assert low == 0x8877665589ABCDEF and high == 0, (hex(low), hex(high))
    cocotb.log.info("Debug strided partial load: VS=%d", (status >> 9) & 3)
    assert (status >> 9) & 3 == 3, (
        "strided partial load changed v8 but left VS non-Dirty"
    )


def _enc_bne(rs1: int, rs2: int, offset: int) -> int:
    imm = offset & 0x1FFE
    return (
        (((imm >> 12) & 1) << 31)
        | (((imm >> 5) & 0x3F) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (1 << 12)
        | (((imm >> 1) & 0xF) << 8)
        | (((imm >> 11) & 1) << 7)
        | 0x63
    )


def _enc_cbo_flush(rs1: int) -> int:
    return (2 << 20) | (rs1 << 15) | (2 << 12) | 0x0F


def _enc_vmem(
    store_op: bool,
    nf: int,
    mop: int,
    vm: int,
    rs2_or_umop: int,
    rs1: int,
    width: int,
    vd: int,
) -> int:
    return (
        ((nf - 1) << 29)
        | (mop << 26)
        | (vm << 25)
        | ((rs2_or_umop & 0x1F) << 20)
        | (rs1 << 15)
        | (width << 12)
        | (vd << 7)
        | (0x27 if store_op else 0x07)
    )


@cocotb.test()
@takes_last_edge
async def test_mid_run_halt_sets_vstart_and_resumes(dut: Any) -> None:
    """Debug haltreq stops strided, indexed, segment and FoF runs at an element boundary."""
    start_clocks((dut.i_clk,), CLK_PERIOD_NS * 1000)
    start_cpu_clock(dut)
    cocotb.start_soon(generate_divided_clock(dut))
    await _reset(dut)
    jtag = JtagDriver(dut, half_period=2)
    await jtag.reset()
    dm = DebugModule(Dtm(jtag, idle_cycles=0), cocotb.log)
    await dm.activate()
    await dm.halt()

    # Scratch GPRs disjoint from S0/S1/a0..a5/t0/t1 for low-overhead progbuf ops.
    t2, t3, t4, t5, t6 = 7, 28, 29, 30, 31

    async def fast_rd_csr(csr: int) -> int:
        await dm.exec_progbuf([csrr(t2, csr)])
        return await dm.read_gpr(t2)

    async def fast_wr_csr(csr: int, val: int) -> None:
        await dm.write_gpr(t2, val)
        await dm.exec_progbuf([csrw(csr, t2)])

    async def fast_rd_m(addr: int, size: int) -> int:
        await dm.write_gpr(t2, addr)
        await dm.exec_progbuf([load(t3, t2, size, unsigned=True)])
        return await dm.read_gpr(t3)

    async def fast_wr_m(addr: int, size: int, val: int) -> None:
        await dm.write_gpr(t2, addr)
        await dm.write_gpr(t3, val)
        await dm.exec_progbuf([store(t3, t2, size)])

    async def fast_wr_w(addr: int, val: int) -> None:
        await fast_wr_m(addr, 4, val)

    # Enable ebreak -> Debug Mode in M-mode and enable VS.
    dcsr = await fast_rd_csr(CSR_DCSR)
    await fast_wr_csr(CSR_DCSR, dcsr | DCSR_EBREAKM)
    await fast_wr_csr(CSR_MSTATUS, (await fast_rd_csr(CSR_MSTATUS)) | (3 << 9))
    vlenb = await fast_rd_csr(0xC22)
    assert vlenb == 32, f"expected VLEN=256 (vlenb=32), got {vlenb}"

    # Memory layout in cached DDR (well away from debug_target).
    code_pc = 0x8350_5000
    init_pc = 0x8350_5100
    idx_pc = 0x8350_5200
    src_base = 0x8351_0000
    dst_base = 0x8352_0000
    vrf_buf = 0x8353_0000
    dump_buf = 0x8353_0400
    idx_buf = 0x8353_0800
    root, l1, l0, frame = 0x8354_0000, 0x8354_1000, 0x8354_2000, 0x8354_3000
    va_base = 0x0040_0000

    # Sv39 page table: page 0 (va_base) mapped to frame, page 1 unmapped (for FoF trim).
    for addr, val in (
        (root, ((l1 >> 12) << 10) | 1),
        (l1 + 16, ((l0 >> 12) << 10) | 1),
        (l0, ((frame >> 12) << 10) | 0xC7),
        (l0 + 8, 0),
    ):
        await dm.write_mem(addr, 8, val)

    # Native helper at init_pc: fills a2 elements at a0 (stride a1) with bytes
    # f0 = (a3 + i) & 0xff and (if a5 != 0) f1 = (a3 + i + 0x40) & 0xff,
    # optionally cbo.flush-ing each element when a4 != 0. Ends with fence + ebreak.
    # Registers: a0=ptr, a1=stride, a2=count, a3=val, a4=flush, a5=nf2, t0=tmp.
    a0, a1, a2, a3, a4, a5, t0 = 10, 11, 12, 13, 14, 15, 5
    init_prog = [
        store(a3, a0, 1, 0),  # 0: sb a3, 0(a0)
        # beq a5, zero, +12 (skip f1 store)
        ((0 << 31) | (0 << 25) | (0 << 20) | (a5 << 15) | (0 << 12) | (6 << 8) | 0x63),
        addi(t0, a3, 0x40),  # 8: addi t0, a3, 0x40
        store(t0, a0, 1, 1),  # 12: sb t0, 1(a0)
        # beq a4, zero, +8 (skip cbo.flush)
        ((0 << 31) | (0 << 25) | (0 << 20) | (a4 << 15) | (0 << 12) | (4 << 8) | 0x63),
        _enc_cbo_flush(a0),  # 20: cbo.flush (a0)
        # add a0, a0, a1
        (0 << 25) | (a1 << 20) | (a0 << 15) | (0 << 12) | (a0 << 7) | 0x33,
        addi(a3, a3, 1),  # 28: addi a3, a3, 1
        addi(a2, a2, -1),  # 32: addi a2, a2, -1
        _enc_bne(a2, 0, -36),  # 36: bne a2, zero, loop (pc-36 -> 0)
        INSN_FENCE,  # 40: fence
        INSN_EBREAK,  # 44: ebreak
    ]
    for i, word in enumerate(init_prog):
        await dm.write_mem(init_pc + 4 * i, 4, word, fence=False)

    # Native index-table builder at idx_pc: writes 128 16-bit offsets (i * 64) to idx_buf.
    idx_prog = [
        store(a3, a0, 2, 0),  # 0: sh a3, 0(a0)
        addi(a0, a0, 2),  # 4: addi a0, a0, 2
        addi(a3, a3, 64),  # 8: addi a3, a3, 64
        addi(a2, a2, -1),  # 12: addi a2, a2, -1
        _enc_bne(a2, 0, -16),  # 16: bne a2, zero, loop
        INSN_FENCE,  # 20: fence
        INSN_EBREAK,  # 24: ebreak
    ]
    for i, word in enumerate(idx_prog):
        await dm.write_mem(idx_pc + 4 * i, 4, word, fence=False)
    await dm.fence_i()

    # Build the 128-entry e16 index buffer once (offsets 0, 64, 128, ..., 127*64)
    # and load v16..v23 once (no case writes v16..v23).
    await dm.write_gpr(a0, idx_buf)
    await dm.write_gpr(a2, 128)
    await dm.write_gpr(a3, 0)
    await fast_wr_csr(CSR_DPC, idx_pc)
    await dm.resume(wait_halted=True)
    assert await fast_rd_csr(CSR_DPC) == idx_pc + 24

    vl8re8_v8 = (7 << 29) | (1 << 25) | (8 << 20) | (dm.S0 << 15) | (8 << 7) | 0x07
    vl8re8_v16 = (7 << 29) | (1 << 25) | (8 << 20) | (dm.S0 << 15) | (16 << 7) | 0x07
    vs8r_v8 = (7 << 29) | (1 << 25) | (8 << 20) | (dm.S0 << 15) | (8 << 7) | 0x27
    # vsetvli t0, zero, e8, m1/m4, tu, mu -> vl = 32 (m1) or 128 (m4) at VLEN=256.
    vsetvli_e8_m1 = (0x00 << 20) | (7 << 12) | (5 << 7) | 0x57
    vsetvli_e8_m4 = (0x02 << 20) | (7 << 12) | (5 << 7) | 0x57
    await dm.write_gpr(dm.S0, idx_buf)
    await dm.exec_progbuf([vl8re8_v16])

    # Install fixed wrapper words around code_pc + 4 once.
    await fast_wr_w(code_pc + 0, csrr(5, 0xC00))  # t0 = cycle before
    await fast_wr_w(code_pc + 8, csrr(6, 0xC00))  # t1 = cycle after
    await fast_wr_w(code_pc + 12, INSN_EBREAK)

    async def run_init(
        base: int, stride: int, count: int, seed: int, *, flush: bool, nf2: bool
    ) -> None:
        await dm.write_gpr(a0, base)
        await dm.write_gpr(a1, stride)
        await dm.write_gpr(a2, count)
        await dm.write_gpr(a3, seed)
        await dm.write_gpr(a4, int(flush))
        await dm.write_gpr(a5, int(nf2))
        await fast_wr_csr(CSR_DPC, init_pc)
        await dm.resume(wait_halted=True)
        assert await fast_rd_csr(CSR_DPC) == init_pc + 44

    async def prepare_case(
        *,
        vl: int,
        is_store: bool,
        nf: int,
        mem_base: int,
        mem_stride: int,
        seed: int,
        flush: bool,
        init_vrf: bool = True,
    ) -> None:
        # Initialize memory and (when requested) VRF staging buffer natively.
        mem_seed = 0x90 if is_store else seed
        reg_seed = seed if is_store else 0xA0
        await run_init(mem_base, mem_stride, vl, mem_seed, flush=flush, nf2=(nf == 2))
        if init_vrf:
            await run_init(vrf_buf, 1, vl, reg_seed, flush=False, nf2=False)
            if nf == 2:
                await run_init(
                    vrf_buf + vl,
                    1,
                    vl,
                    (reg_seed + 0x40) & 0xFF,
                    flush=False,
                    nf2=False,
                )
            await fast_wr_csr(0x008, 0)
            await dm.write_gpr(dm.S0, vrf_buf)
            await dm.exec_progbuf([vl8re8_v8])

    cases = [
        # (name, insn, vl, is_store, nf, phys_base, va_base, stride, seed, flush, indexed, sv39, expect_vl)
        (
            "strided_ld",
            _enc_vmem(False, 1, 2, 1, dm.S1, dm.S0, 0, 8),
            32,
            False,
            1,
            src_base,
            src_base,
            64,
            0x11,
            True,
            False,
            False,
            32,
        ),
        (
            "strided_st",
            _enc_vmem(True, 1, 2, 1, dm.S1, dm.S0, 0, 8),
            32,
            True,
            1,
            dst_base,
            dst_base,
            64,
            0x21,
            True,
            False,
            False,
            32,
        ),
        (
            "indexed_ld",
            _enc_vmem(False, 1, 1, 1, 16, dm.S0, 5, 8),
            32,
            False,
            1,
            src_base,
            src_base,
            64,
            0x31,
            True,
            True,
            False,
            32,
        ),
        (
            "indexed_st",
            _enc_vmem(True, 1, 3, 1, 16, dm.S0, 5, 8),
            32,
            True,
            1,
            dst_base,
            dst_base,
            64,
            0x41,
            True,
            True,
            False,
            32,
        ),
        (
            "seg2_ld",
            _enc_vmem(False, 2, 2, 1, dm.S1, dm.S0, 0, 8),
            32,
            False,
            2,
            src_base,
            src_base,
            64,
            0x51,
            True,
            False,
            False,
            32,
        ),
        (
            "seg2_st",
            _enc_vmem(True, 2, 2, 1, dm.S1, dm.S0, 0, 8),
            32,
            True,
            2,
            dst_base,
            dst_base,
            64,
            0x61,
            True,
            False,
            False,
            32,
        ),
        (
            "fof_trim",
            _enc_vmem(False, 1, 0, 1, 0x10, dm.S0, 0, 8),
            128,
            False,
            1,
            frame + 4096 - 96,
            va_base + 4096 - 96,
            1,
            0x71,
            True,
            False,
            True,
            96,
        ),
        (
            "fof_seg2_trim",
            _enc_vmem(False, 2, 0, 1, 0x10, dm.S0, 0, 8),
            128,
            False,
            2,
            frame + 4096 - 192,
            va_base + 4096 - 192,
            2,
            0x81,
            True,
            False,
            True,
            96,
        ),
    ]

    for (
        name,
        insn,
        vl,
        is_store,
        nf,
        phys_base,
        eff_base,
        stride,
        seed,
        flush,
        indexed,
        sv39,
        expect_vl,
    ) in cases:
        vset_insn = vsetvli_e8_m1 if vl == 32 else vsetvli_e8_m4
        await fast_wr_w(code_pc + 4, insn)
        await dm.fence_i()
        insn_pc = code_pc + 4

        # Step 1: uninterrupted baseline to measure full-instruction cycles.
        await fast_wr_csr(0x180, 0)
        await fast_wr_csr(CSR_MSTATUS, (await fast_rd_csr(CSR_MSTATUS)) & ~(1 << 17))
        await prepare_case(
            vl=vl,
            is_store=is_store,
            nf=nf,
            mem_base=phys_base,
            mem_stride=stride,
            seed=seed,
            flush=flush,
            init_vrf=False,
        )
        await fast_wr_csr(0x008, 0)
        await dm.exec_progbuf([vset_insn])
        if sv39:
            await fast_wr_csr(0x180, (8 << 60) | (root >> 12))
            await dm.exec_progbuf([0x12000073])  # sfence.vma
            st_base = await fast_rd_csr(CSR_MSTATUS)
            await fast_wr_csr(
                CSR_MSTATUS, (st_base & ~(3 << 11)) | (1 << 11) | (1 << 17)
            )
        await dm.write_gpr(dm.S0, eff_base)
        await dm.write_gpr(dm.S1, stride)
        await fast_wr_csr(CSR_DPC, code_pc)
        await dm.resume(wait_halted=True)
        assert await fast_rd_csr(CSR_DPC) == code_pc + 12, name
        t_full = (await dm.read_gpr(6)) - (await dm.read_gpr(5))
        assert await fast_rd_csr(0xC20) == expect_vl, name
        assert await fast_rd_csr(0x008) == 0, name

        # Step 2: mid-run debug halt + prestart verification/poison + dret resume.
        await fast_wr_csr(0x180, 0)
        await fast_wr_csr(CSR_MSTATUS, (await fast_rd_csr(CSR_MSTATUS)) & ~(1 << 17))
        await prepare_case(
            vl=vl,
            is_store=is_store,
            nf=nf,
            mem_base=phys_base,
            mem_stride=stride,
            seed=seed,
            flush=flush,
            init_vrf=True,
        )
        await dm.exec_progbuf([vset_insn])
        if sv39:
            await fast_wr_csr(0x180, (8 << 60) | (root >> 12))
            await dm.exec_progbuf([0x12000073])  # sfence.vma
        st_pre = await fast_rd_csr(CSR_MSTATUS)
        # Enter the vector instruction with mstatus.VS = Clean (2) to verify
        # mid-run halt dirties VS on both loads and stores.
        st_clean = (st_pre & ~((3 << 9) | (3 << 11) | (1 << 17))) | (2 << 9)
        if sv39:
            st_clean |= (1 << 11) | (1 << 17)
        await fast_wr_csr(CSR_MSTATUS, st_clean)
        await dm.write_gpr(dm.S0, eff_base)
        await dm.write_gpr(dm.S1, stride)
        await fast_wr_csr(CSR_DPC, insn_pc)

        # Resume and immediately assert haltreq over JTAG while the run is in
        # flight; count polls and core cycles until allhalted.
        await dm.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE | DMCONTROL_RESUMEREQ)
        await dm.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE | DMCONTROL_HALTREQ)
        t_req = int(get_sim_time("ns"))
        polls = 0
        while True:
            polls += 1
            st = await dm.dmstatus()
            if st & DMSTATUS_ALLHALTED:
                break
            assert polls < 200, f"{name}: timeout waiting for mid-run halt"
        t_halt = int(get_sim_time("ns"))
        await dm.dtm.write(DM_DMCONTROL, DMCONTROL_DMACTIVE)
        halt_cycles = (t_halt - t_req) // CLK_PERIOD_NS

        # Capture dpc, dcsr, mstatus, vstart, vl in one progbuf execution.
        await dm.exec_progbuf(
            [
                csrr(t2, CSR_DPC),
                csrr(t3, CSR_DCSR),
                csrr(t4, CSR_MSTATUS),
                csrr(t5, 0x008),
                csrr(t6, 0xC20),
            ]
        )
        dpc = await dm.read_gpr(t2)
        dcsr_now = await dm.read_gpr(t3)
        mstatus_halt = await dm.read_gpr(t4)
        vstart_halt = await dm.read_gpr(t5)
        vl_halt = await dm.read_gpr(t6)
        cause = (dcsr_now & DCSR_CAUSE_MASK) >> DCSR_CAUSE_SHIFT

        cocotb.log.info(
            "DEBUG_HALT %-14s full=%d halt_lat=%d polls=%d vstart=%d/%d vs=%d dpc=%#x",
            name,
            t_full,
            halt_cycles,
            polls,
            vstart_halt,
            vl_halt,
            (mstatus_halt >> 9) & 3,
            dpc,
        )
        assert dpc == insn_pc, (name, hex(dpc), hex(insn_pc))
        assert cause == DCSR_CAUSE_HALTREQ, (name, cause)
        assert 0 < vstart_halt < expect_vl, (name, vstart_halt, expect_vl)
        assert vl_halt == vl, (name, vl_halt, vl)
        assert (mstatus_halt >> 9) & 3 == 3, (
            f"{name}: mid-run halt left mstatus.VS non-Dirty"
        )
        assert halt_cycles < t_full, (name, halt_cycles, t_full)

        # Temporarily clear MPRV so progbuf memory checks use physical DDR.
        if sv39:
            await fast_wr_csr(CSR_MSTATUS, mstatus_halt & ~(1 << 17))
        saved_s0 = await dm.read_gpr(dm.S0)
        poison_elems = sorted({0, vstart_halt - 1})
        poison_byte = 0xE7
        poison_val = poison_byte | ((poison_byte << 8) if nf == 2 else 0)

        if not is_store:
            # Save v8..v15 with vstart=0, inspect prestart & post-vstart lanes,
            # poison prestart source bytes, then restore vstart.
            await fast_wr_csr(0x008, 0)
            await dm.write_gpr(dm.S0, dump_buf)
            await dm.exec_progbuf([vs8r_v8])
            for elem in poison_elems:
                for f in range(nf):
                    got = await fast_rd_m(dump_buf + f * vl + elem, 1)
                    want = (seed + elem + (0x40 if f else 0)) & 0xFF
                    assert got == want, (
                        name,
                        "prestart_ld",
                        elem,
                        f,
                        hex(got),
                        hex(want),
                    )
            for elem in sorted({vstart_halt, expect_vl - 1}):
                for f in range(nf):
                    got = await fast_rd_m(dump_buf + f * vl + elem, 1)
                    want = (0xA0 + elem + (0x40 if f else 0)) & 0xFF
                    assert got == want, (
                        name,
                        "unstarted_ld",
                        elem,
                        f,
                        hex(got),
                        hex(want),
                    )
            for elem in poison_elems:
                await fast_wr_m(phys_base + elem * stride, nf, poison_val)
        else:
            for elem in poison_elems:
                got_pair = await fast_rd_m(phys_base + elem * stride, nf)
                for f in range(nf):
                    got = (got_pair >> (8 * f)) & 0xFF
                    want = (seed + elem + (0x40 if f else 0)) & 0xFF
                    assert got == want, (
                        name,
                        "prestart_st",
                        elem,
                        f,
                        hex(got),
                        hex(want),
                    )
            for elem in sorted({vstart_halt, expect_vl - 1}):
                got_pair = await fast_rd_m(phys_base + elem * stride, nf)
                for f in range(nf):
                    got = (got_pair >> (8 * f)) & 0xFF
                    want = (0x90 + elem + (0x40 if f else 0)) & 0xFF
                    assert got == want, (
                        name,
                        "unstarted_st",
                        elem,
                        f,
                        hex(got),
                        hex(want),
                    )
            for elem in poison_elems:
                await fast_wr_m(phys_base + elem * stride, nf, poison_val)

        await dm.write_gpr(dm.S0, saved_s0)
        await fast_wr_csr(0x008, vstart_halt)
        if sv39:
            await fast_wr_csr(CSR_MSTATUS, mstatus_halt)

        # Resume via dret and wait for ebreak after instruction completes.
        await dm.resume(wait_halted=True)
        await dm.exec_progbuf(
            [csrr(t2, CSR_DPC), csrr(t3, CSR_DCSR), csrr(t4, 0x008), csrr(t5, 0xC20)]
        )
        dpc_after = await dm.read_gpr(t2)
        cause_after = ((await dm.read_gpr(t3)) & DCSR_CAUSE_MASK) >> DCSR_CAUSE_SHIFT
        assert dpc_after == code_pc + 12, (name, hex(dpc_after))
        assert cause_after == DCSR_CAUSE_EBREAK, (name, cause_after)
        assert await dm.read_gpr(t4) == 0, (name, "vstart after dret resume")
        assert await dm.read_gpr(t5) == expect_vl, (name, "vl after dret resume")

        # Verify final architectural state (and prestart non-rewriting).
        if sv39:
            await fast_wr_csr(
                CSR_MSTATUS, (await fast_rd_csr(CSR_MSTATUS)) & ~(1 << 17)
            )
            await fast_wr_csr(0x180, 0)
        if not is_store:
            await dm.write_gpr(dm.S0, dump_buf)
            await dm.exec_progbuf([vs8r_v8])
            check_elems = sorted(
                set(poison_elems) | {vstart_halt, expect_vl - 1, min(expect_vl, vl - 1)}
            )
            for elem in check_elems:
                for f in range(nf):
                    got = await fast_rd_m(dump_buf + f * vl + elem, 1)
                    if elem < expect_vl:
                        want = (seed + elem + (0x40 if f else 0)) & 0xFF
                    else:
                        want = (0xA0 + elem + (0x40 if f else 0)) & 0xFF
                    assert got == want, (name, "final_ld", elem, f, hex(got), hex(want))
        else:
            check_elems = sorted(set(poison_elems) | {vstart_halt, vl - 1})
            for elem in check_elems:
                got_pair = await fast_rd_m(phys_base + elem * stride, nf)
                for f in range(nf):
                    got = (got_pair >> (8 * f)) & 0xFF
                    if elem in poison_elems:
                        want = poison_byte
                    else:
                        want = (seed + elem + (0x40 if f else 0)) & 0xFF
                    assert got == want, (name, "final_st", elem, f, hex(got), hex(want))


@cocotb.test()
@takes_last_edge
async def test_single_step_strided_load_and_store(dut: Any) -> None:
    """Single-stepping over a strided load or store completes the whole instruction."""
    start_clocks((dut.i_clk,), CLK_PERIOD_NS * 1000)
    start_cpu_clock(dut)
    cocotb.start_soon(generate_divided_clock(dut))
    await _reset(dut)
    jtag = JtagDriver(dut, half_period=2)
    await jtag.reset()
    dm = DebugModule(Dtm(jtag, idle_cycles=0), cocotb.log)
    await dm.activate()
    await dm.halt()

    t2, t3, t4, t5 = 7, 28, 29, 30
    a0, a1, a2, a3, a4 = 10, 11, 12, 13, 14

    async def fast_rd_csr(csr: int) -> int:
        await dm.exec_progbuf([csrr(t2, csr)])
        return await dm.read_gpr(t2)

    async def fast_wr_csr(csr: int, val: int) -> None:
        await dm.write_gpr(t2, val)
        await dm.exec_progbuf([csrw(csr, t2)])

    async def fast_rd_m(addr: int, size: int) -> int:
        await dm.write_gpr(t2, addr)
        await dm.exec_progbuf([load(t3, t2, size, unsigned=True)])
        return await dm.read_gpr(t3)

    async def fast_wr_m(addr: int, size: int, val: int) -> None:
        await dm.write_gpr(t2, addr)
        await dm.write_gpr(t3, val)
        await dm.exec_progbuf([store(t3, t2, size)])

    # Enable ebreak -> Debug Mode in M-mode and enable VS.
    dcsr_base = (await fast_rd_csr(CSR_DCSR)) | DCSR_EBREAKM
    await fast_wr_csr(CSR_DCSR, dcsr_base & ~DCSR_STEP)
    await fast_wr_csr(CSR_MSTATUS, (await fast_rd_csr(CSR_MSTATUS)) | (3 << 9))

    code_pc = 0x8350_6000
    init_pc = 0x8350_6100
    src_base = 0x8355_0000
    dst_base = 0x8356_0000
    vrf_buf = 0x8357_0000
    dump_buf = 0x8357_0400

    # Native helper at init_pc: stores (a3 + i) & 0xff at a0 + i*a1 for a2 elements,
    # optionally cbo.flush-ing each line when a4 != 0, then fence + ebreak.
    init_prog = [
        store(a3, a0, 1, 0),  # 0: sb a3, 0(a0)
        ((0 << 31) | (0 << 25) | (0 << 20) | (a4 << 15) | (0 << 12) | (4 << 8) | 0x63),
        _enc_cbo_flush(a0),  # 8: cbo.flush (a0)
        (0 << 25) | (a1 << 20) | (a0 << 15) | (0 << 12) | (a0 << 7) | 0x33,
        addi(a3, a3, 1),  # 16: addi a3, a3, 1
        addi(a2, a2, -1),  # 20: addi a2, a2, -1
        _enc_bne(a2, 0, -24),  # 24: bne a2, zero, loop
        INSN_FENCE,  # 28: fence
        INSN_EBREAK,  # 32: ebreak
    ]
    for i, word in enumerate(init_prog):
        await dm.write_mem(init_pc + 4 * i, 4, word, fence=False)
    await dm.fence_i()

    async def run_init(
        base: int, stride: int, count: int, seed: int, *, flush: bool
    ) -> None:
        await fast_wr_csr(CSR_DCSR, dcsr_base & ~DCSR_STEP)
        await dm.write_gpr(a0, base)
        await dm.write_gpr(a1, stride)
        await dm.write_gpr(a2, count)
        await dm.write_gpr(a3, seed)
        await dm.write_gpr(a4, int(flush))
        await fast_wr_csr(CSR_DPC, init_pc)
        await dm.resume(wait_halted=True)
        assert await fast_rd_csr(CSR_DPC) == init_pc + 32

    vl = 16
    stride = 64
    # vsetivli x0, 16, e8, m1, tu, mu -> vl = 16
    vsetivli_16_e8 = (3 << 30) | (0x00 << 20) | (16 << 15) | (7 << 12) | (0 << 7) | 0x57
    vl1re8_v8 = (
        (0 << 29) | (1 << 25) | (8 << 20) | (dm.S0 << 15) | (0 << 12) | (8 << 7) | 0x07
    )
    vs1r_v8 = (
        (0 << 29) | (1 << 25) | (8 << 20) | (dm.S0 << 15) | (0 << 12) | (8 << 7) | 0x27
    )
    vlse8_v8 = _enc_vmem(False, 1, 2, 1, dm.S1, dm.S0, 0, 8)
    vsse8_v8 = _enc_vmem(True, 1, 2, 1, dm.S1, dm.S0, 0, 8)

    async def check_v8_bytes(tag: str, seed: int) -> None:
        await dm.write_gpr(dm.S0, dump_buf)
        await dm.exec_progbuf([vs1r_v8])
        lo = await fast_rd_m(dump_buf, 8)
        hi = await fast_rd_m(dump_buf + 8, 8)
        for elem in range(vl):
            word = lo if elem < 8 else hi
            got = (word >> (8 * (elem & 7))) & 0xFF
            want = (seed + elem) & 0xFF
            assert got == want, (tag, elem, hex(got), hex(want))

    # 1. Single-step over a cold-line strided load (16 elements across 16 cache lines).
    #    Verify the whole load completes before halting, vstart returns to 0, VS becomes
    #    Dirty, and all 16 elements land in v8.
    await run_init(src_base, stride, vl, 0x31, flush=True)
    await run_init(vrf_buf, 1, vl, 0xA0, flush=False)
    await fast_wr_csr(0x008, 0)
    await dm.write_gpr(dm.S0, vrf_buf)
    await dm.exec_progbuf([vsetivli_16_e8, vl1re8_v8])
    assert await fast_rd_csr(0xC20) == vl
    await fast_wr_m(code_pc + 0, 4, vlse8_v8)
    await fast_wr_m(code_pc + 4, 4, INSN_NOP)
    await fast_wr_m(code_pc + 8, 4, INSN_EBREAK)
    await dm.fence_i()

    mstatus_clean = ((await fast_rd_csr(CSR_MSTATUS)) & ~(3 << 9)) | (2 << 9)
    await fast_wr_csr(CSR_MSTATUS, mstatus_clean)
    await dm.write_gpr(dm.S0, src_base)
    await dm.write_gpr(dm.S1, stride)
    await fast_wr_csr(CSR_DPC, code_pc)
    await fast_wr_csr(CSR_DCSR, dcsr_base | DCSR_STEP)
    await dm.resume(wait_halted=True)

    await dm.exec_progbuf(
        [csrr(t2, CSR_DPC), csrr(t3, CSR_DCSR), csrr(t4, 0x008), csrr(t5, CSR_MSTATUS)]
    )
    dpc = await dm.read_gpr(t2)
    cause = ((await dm.read_gpr(t3)) & DCSR_CAUSE_MASK) >> DCSR_CAUSE_SHIFT
    vstart_after = await dm.read_gpr(t4)
    vs_after = ((await dm.read_gpr(t5)) >> 9) & 3
    cocotb.log.info(
        "STEP strided_ld dpc=%#x cause=%d vstart=%d vs=%d",
        dpc,
        cause,
        vstart_after,
        vs_after,
    )
    assert dpc == code_pc + 4, (hex(dpc), hex(code_pc + 4))
    assert cause == DCSR_CAUSE_STEP, cause
    assert vstart_after == 0, vstart_after
    assert vs_after == 3, vs_after
    await check_v8_bytes("step_ld", 0x31)

    # 2. Single-step over a cold-line strided store (16 elements across 16 cache lines).
    #    Verify the whole store completes before halting, vstart == 0, and all 16
    #    memory locations receive their stored bytes.
    await run_init(dst_base, stride, vl, 0x90, flush=True)
    await run_init(vrf_buf, 1, vl, 0x51, flush=False)
    await fast_wr_csr(0x008, 0)
    await dm.write_gpr(dm.S0, vrf_buf)
    await dm.exec_progbuf([vsetivli_16_e8, vl1re8_v8])
    assert await fast_rd_csr(0xC20) == vl
    await fast_wr_m(code_pc + 0, 4, vsse8_v8)
    await fast_wr_m(code_pc + 4, 4, INSN_NOP)
    await fast_wr_m(code_pc + 8, 4, INSN_EBREAK)
    await dm.fence_i()

    await dm.write_gpr(dm.S0, dst_base)
    await dm.write_gpr(dm.S1, stride)
    await fast_wr_csr(CSR_DPC, code_pc)
    await fast_wr_csr(CSR_DCSR, dcsr_base | DCSR_STEP)
    await dm.resume(wait_halted=True)

    await dm.exec_progbuf([csrr(t2, CSR_DPC), csrr(t3, CSR_DCSR), csrr(t4, 0x008)])
    dpc = await dm.read_gpr(t2)
    cause = ((await dm.read_gpr(t3)) & DCSR_CAUSE_MASK) >> DCSR_CAUSE_SHIFT
    vstart_after = await dm.read_gpr(t4)
    cocotb.log.info(
        "STEP strided_st dpc=%#x cause=%d vstart=%d", dpc, cause, vstart_after
    )
    assert dpc == code_pc + 4, (hex(dpc), hex(code_pc + 4))
    assert cause == DCSR_CAUSE_STEP, cause
    assert vstart_after == 0, vstart_after

    for elem in range(vl):
        got = await fast_rd_m(dst_base + elem * stride, 1)
        want = (0x51 + elem) & 0xFF
        assert got == want, ("step_st", elem, hex(got), hex(want))

    # 3. Single-step over a cold-line strided load with an enabled MTI pending
    #    (dcsr.stepie is hardwired 0): the step masks the interrupt throughout the
    #    run, completes all 16 elements, clears vstart, and halts at code_pc + 4.
    await run_init(src_base, stride, vl, 0x71, flush=True)
    await run_init(vrf_buf, 1, vl, 0xC0, flush=False)
    await fast_wr_csr(0x008, 0)
    await dm.write_gpr(dm.S0, vrf_buf)
    await dm.exec_progbuf([vsetivli_16_e8, vl1re8_v8])
    assert await fast_rd_csr(0xC20) == vl
    await fast_wr_m(code_pc + 0, 4, vlse8_v8)
    await fast_wr_m(code_pc + 4, 4, INSN_NOP)
    await fast_wr_m(code_pc + 8, 4, INSN_EBREAK)
    await dm.fence_i()

    # Arm MTI immediately (mtimecmp = 0, mie.MTIE = 1, mstatus.MIE = 1).
    await fast_wr_m(0x4000_0018, 4, 0)
    await fast_wr_m(0x4000_001C, 4, 0)
    await fast_wr_csr(0x304, 1 << 7)  # mie.MTIE
    await fast_wr_csr(CSR_MSTATUS, (await fast_rd_csr(CSR_MSTATUS)) | (1 << 3))
    await dm.write_gpr(dm.S0, src_base)
    await dm.write_gpr(dm.S1, stride)
    await fast_wr_csr(CSR_DPC, code_pc)
    await fast_wr_csr(CSR_DCSR, dcsr_base | DCSR_STEP)
    await dm.resume(wait_halted=True)

    await dm.exec_progbuf([csrr(t2, CSR_DPC), csrr(t3, CSR_DCSR), csrr(t4, 0x008)])
    dpc = await dm.read_gpr(t2)
    cause = ((await dm.read_gpr(t3)) & DCSR_CAUSE_MASK) >> DCSR_CAUSE_SHIFT
    vstart_after = await dm.read_gpr(t4)
    # Disarm MTI cleanly before reading back v8.
    await fast_wr_m(0x4000_001C, 4, 0xFFFF_FFFF)
    await fast_wr_csr(0x304, 0)
    await fast_wr_csr(CSR_MSTATUS, (await fast_rd_csr(CSR_MSTATUS)) & ~(1 << 3))
    await fast_wr_csr(CSR_DCSR, dcsr_base & ~DCSR_STEP)

    cocotb.log.info(
        "STEP strided_ld_mti dpc=%#x cause=%d vstart=%d", dpc, cause, vstart_after
    )
    assert dpc == code_pc + 4, (hex(dpc), hex(code_pc + 4))
    assert cause == DCSR_CAUSE_STEP, cause
    assert vstart_after == 0, vstart_after
    await check_v8_bytes("step_ld_mti", 0x71)
