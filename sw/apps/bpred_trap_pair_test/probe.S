/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

/*
 * Low-level trap entry, privilege-switch runner, and static low-memory stubs
 * for bpred_trap_pair_test.
 */

    .section .text
    .option push
    .option norelax

    .balign 4
    .globl trap_pair_handler
trap_pair_handler:
    la      t0, g_trap_scratch
    sd      t1, 0(t0)
    sd      t2, 8(t0)
    sd      t3, 16(t0)

    /* Sample ITLB walks and profiling counters before restoring M-mode state. */
    csrr    t1, 0xB05
    la      t2, g_after_walks
    sd      t1, 0(t2)

    /* Save dead-slot register canary s11 before M-mode restore overwrites it. */
    la      t2, g_after_canary
    sd      s11, 0(t2)

    csrr    t1, mcause
    csrr    t2, mepc
    csrr    t3, mtval

    la      t0, g_last_cause
    sd      t1, 0(t0)
    la      t0, g_last_epc
    sd      t2, 0(t0)
    la      t0, g_last_tval
    sd      t3, 0(t0)

    la      t0, g_trap_count
    ld      t1, 0(t0)
    addi    t1, t1, 1
    sd      t1, 0(t0)

    la      t0, g_resume_pc
    ld      t1, 0(t0)
    csrw    mepc, t1

    /* Return to M-mode (MPP = 3) at g_resume_pc. */
    li      t1, 0x1800
    csrs    mstatus, t1

    la      t0, g_trap_scratch
    ld      t1, 0(t0)
    ld      t2, 8(t0)
    ld      t3, 16(t0)
    mret

/*
 * uint64_t run_priv_probe(uint64_t entry_va,   // a0
 *                         uint64_t arg_t1,     // a1
 *                         uint64_t arg_a0,     // a2
 *                         uint64_t priv_mpp,   // a3: 0=U, 1=S, 3=M
 *                         uint64_t satp_val,   // a4
 *                         uint64_t mstatus_or, // a5: e.g. TW / TSR bits
 *                         uint64_t flush_va_a, // a6: 0 or page VA to sfence
 *                         uint64_t flush_va_b) // a7: 0 or second page VA to sfence
 */
    .balign 4
    .globl run_priv_probe
run_priv_probe:
    la      t0, g_host_save
    sd      ra, 0(t0)
    sd      sp, 8(t0)
    sd      s0, 16(t0)
    sd      s1, 24(t0)
    sd      s2, 32(t0)
    sd      s3, 40(t0)
    sd      s4, 48(t0)
    sd      s5, 56(t0)
    sd      s6, 64(t0)
    sd      s7, 72(t0)
    sd      s8, 80(t0)
    sd      s9, 88(t0)
    sd      s10, 96(t0)
    sd      s11, 104(t0)

    la      t1, 9f
    la      t2, g_resume_pc
    sd      t1, 0(t2)

    /* Install satp; leave existing warm code-page TLB entries intact. */
    csrw    satp, a4

    /* Selectively evict target code pages so any redirect walks the ITLB. */
    beqz    a6, 1f
    sfence.vma a6, zero
1:  beqz    a7, 2f
    sfence.vma a7, zero
2:
    /* Set up mepc and mstatus (MPP + requested TW/TSR flags). */
    csrw    mepc, a0
    li      t1, 0x007E1800      /* clear TW (21), TSR (22), MPP (12:11), etc. */
    csrc    mstatus, t1
    slli    t2, a3, 11
    or      t2, t2, a5
    csrs    mstatus, t2

    /* Set S-mode return target to our S-mode landing pad in VA_PROBE (+0x040)
     * or M-mode landing pad when testing xRET instructions directly. */
    la      t0, g_sret_epc
    ld      t1, 0(t0)
    csrw    sepc, t1
    li      t1, 0x0100          /* sstatus.SPP = 1 (stay in S-mode on sret) */
    csrs    sstatus, t1

    /* Clear dead-slot canary s11 and set t1 / a0 for the probe body. */
    li      s11, 0
    mv      t1, a1
    mv      a0, a2
    la      ra, probe_m_return_pad

    /* Snapshot mperf counter 31 (IF_SLOT2_PRED_TAKEN) when implemented, plus ITLB walks. */
    la      t0, g_has_mperf
    lw      t0, 0(t0)
    beqz    t0, 3f
    li      t0, 1
    csrw    0x7C1, t0           /* CSR_MPERFCTL snapshot */
    li      t0, 31
    csrw    0x7C0, t0           /* CSR_MPERFSEL = IF_SLOT2_PRED_TAKEN */
    csrr    t2, 0xFC0           /* CSR_MPERFDATA */
    la      t0, g_before_s2_pred
    sd      t2, 0(t0)
3:
    csrr    t2, 0xB05           /* mhpmcounter5 (ITLB walks) */
    la      t0, g_before_walks
    sd      t2, 0(t0)

    mret

    .balign 4
    .globl probe_m_return_pad
probe_m_return_pad:
    /* Reached when a non-trapping M-mode probe returns via mret. */
    csrr    t1, 0xB05
    la      t2, g_after_walks
    sd      t1, 0(t2)
    la      t2, g_after_canary
    sd      s11, 0(t2)

9:  /* Snapshot post-probe IF_SLOT2_PRED_TAKEN delta when implemented. */
    la      t0, g_has_mperf
    lw      t0, 0(t0)
    beqz    t0, 4f
    li      t0, 1
    csrw    0x7C1, t0
    li      t0, 31
    csrw    0x7C0, t0
    csrr    t2, 0xFC0
    la      t0, g_after_s2_pred
    sd      t2, 0(t0)
4:

    /* Return to bare M-mode translation. */
    csrw    satp, zero

    la      t0, g_host_save
    ld      ra, 0(t0)
    ld      sp, 8(t0)
    ld      s0, 16(t0)
    ld      s1, 24(t0)
    ld      s2, 32(t0)
    ld      s3, 40(t0)
    ld      s4, 48(t0)
    ld      s5, 56(t0)
    ld      s6, 64(t0)
    ld      s7, 72(t0)
    ld      s8, 80(t0)
    ld      s9, 88(t0)
    ld      s10, 96(t0)
    ld      s11, 104(t0)
    ret

/*
 * Static 4 KiB code page in .text (fetched through imem_predecode in BRAM
 * builds and offline bank init files on FPGA). Mapped at VA_STATIC (0xC0005000)
 * alongside VA_TGT_A (0xC0006000) right above it (+0x1000).
 *
 * Offsets within static_probe_page:
 *   0x000: warm landing pad (ecall)
 *   0x080: history primer A -> jumps to 0x100 (c.ebreak lo + c.jalr t1)
 *   0x0C0: history primer A -> jumps to 0x122 (c.ebreak hi + c.jalr t1)
 *   0x100: [c.ebreak (0x9002) at +0x100, c.jalr t1 (0x9302) at +0x102]
 *   0x120: c.nop; [c.ebreak (0x9002) at +0x122, c.jalr t1 (0x9302) at +0x124]
 *   0x140: [0x0000 (reserved RVC) at +0x140, c.jalr t1 (0x9302) at +0x142]
 *   0x160: c.nop; [0x8002 (reserved C.JR x0) at +0x162, c.jalr t1 (0x9302) at +0x164]
 *   0xEA0: history primer A -> jumps to 0xF80 (slot-1 reserved OPC_BRANCH -> +0x80 = 0x1000)
 *   0xEC0: history primer A -> jumps to 0xFA0 (slot-2 cur_hi reserved OPC_BRANCH -> +0x5E = 0x1000)
 *   0xEE0: history primer A -> jumps to 0xFC0 (slot-2 next_lo reserved OPC_BRANCH -> +0x3C = 0x1000)
 *   0xF80: reserved OPC_BRANCH funct3=010 targeting +0x80 (VA_STATIC + 0x1000)
 *   0xFA0: c.addi a0, 1; reserved OPC_BRANCH funct3=011 at 0xFA2 targeting +0x5E (VA_STATIC + 0x1000)
 *   0xFC0: addi a0, a0, 1; reserved OPC_BRANCH funct3=010 at 0xFC4 targeting +0x3C (VA_STATIC + 0x1000)
 */
    .balign 4096
    .globl static_probe_page
static_probe_page:
    /* 0x000: warm ITLB entry for VA_STATIC */
    ecall

    .org static_probe_page + 0x080
    .option push
    .option norvc
    li      t3, 136
1:  addi    t3, t3, -1
    bnez    t3, 1b
    j       static_probe_page + 0x100
    .option pop

    .org static_probe_page + 0x0C0
    .option push
    .option norvc
    li      t3, 136
1:  addi    t3, t3, -1
    bnez    t3, 1b
    j       static_probe_page + 0x122
    .option pop

    .org static_probe_page + 0x100
    .half   0x9002              /* +0x100 (lo): c.ebreak */
    .half   0x9302              /* +0x102: c.jalr t1 */
    .half   0x0DB5              /* +0x104: c.addi s11, 1 */
    .half   0x0001
    ecall

    .org static_probe_page + 0x120
    .half   0x0001              /* +0x120: c.nop */
    .half   0x9002              /* +0x122 (hi): c.ebreak */
    .half   0x9302              /* +0x124: c.jalr t1 */
    .half   0x0DB5              /* +0x126: c.addi s11, 1 */
    ecall

    .org static_probe_page + 0x140
    .half   0x0000              /* +0x140 (lo): reserved C.ADDI4SPN 0 */
    .half   0x9302              /* +0x142: c.jalr t1 */
    .half   0x0DB5
    .half   0x0001
    ecall

    .org static_probe_page + 0x160
    .half   0x0001              /* +0x160: c.nop */
    .half   0x8002              /* +0x162 (hi): reserved C.JR x0 */
    .half   0x9302              /* +0x164: c.jalr t1 */
    .half   0x0DB5
    ecall

    .org static_probe_page + 0xEA0
    .option push
    .option norvc
    li      t3, 16
1:  addi    t3, t3, -1
    bnez    t3, 1b
    j       static_probe_page + 0xF80
    .option pop

    .org static_probe_page + 0xEC0
    .option push
    .option norvc
    li      t3, 16
1:  addi    t3, t3, -1
    bnez    t3, 1b
    j       static_probe_page + 0xFA0
    .option pop

    .org static_probe_page + 0xEE0
    .option push
    .option norvc
    li      t3, 16
1:  addi    t3, t3, -1
    bnez    t3, 1b
    j       static_probe_page + 0xFC0
    .option pop

    /* 0xF80: Slot-1 reserved OPC_BRANCH (funct3=010, imm=+0x80 -> +0x1000)
     * Encoding: imm=+0x80 (bit7=1 -> insn[27]=1), funct3=010 -> 0x08002063 */
    .org static_probe_page + 0xF80
    .word   0x08002063
    .word   0x001D8D93          /* addi s11, s11, 1 */
    ecall

    /* 0xFA0: Slot-2 cur_hi spanning reserved OPC_BRANCH (funct3=011, imm=+0x5E -> +0x1000)
     * imm=+0x5E (94 = 0b0101_1110: imm[10:5]=000010 -> [26]=1; imm[4:1]=1111 -> [11:8]=0xF)
     * (0x02 << 25) | (3 << 12) | (0xF << 8) | 0x63 = 0x04003F63 */
    .org static_probe_page + 0xFA0
    .half   0x0505              /* +0xFA0: c.addi a0, 1 */
    .4byte  0x04003F63          /* +0xFA2..0xFA5: spanning reserved OPC_BRANCH funct3=011 */
    .half   0x0DB5              /* +0xFA6: c.addi s11, 1 */
    ecall

    /* 0xFC0: Slot-2 next_lo aligned reserved OPC_BRANCH (funct3=010, imm=+0x3C -> +0x1000)
     * imm=+0x3C (60 = 0b0011_1100: imm[10:5]=000001 -> [25]=1; imm[4:1]=1110 -> [11:8]=0xE)
     * (0x01 << 25) | (2 << 12) | (0xE << 8) | 0x63 = 0x02002E63 */
    .org static_probe_page + 0xFC0
    .word   0x00150513          /* +0xFC0: addi a0, a0, 1 */
    .word   0x02002E63          /* +0xFC4: aligned reserved OPC_BRANCH funct3=010 */
    .word   0x001D8D93          /* +0xFC8: addi s11, s11, 1 */
    ecall

    .org static_probe_page + 0x1000
    .option pop
