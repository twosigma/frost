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
 * Assembly helpers and page-aligned stubs for fast_btb_contract_test:
 *   1. Same-side M->M load-fault trap and mret after a flushed speculative
 *      JALR (measures cycle delta while verifying identical architectural state).
 *   2. Same-side mstatus write preserving a flushed speculative JALR entry.
 *   3. Flushed wrong-path JALR training the interior halfword P of a 32-bit LUI
 *      with a same-word covering phantom target (P + 4 inside a 32-bit addi at
 *      P + 2), walked past cleanly on the architectural path.
 *   4. Page-aligned branch/ALU stubs for Sv39 SFENCE.VMA and satp-write BTB
 *      invalidation without FENCE.I.
 */

    .option push
    .option norelax
    .option norvc

/* --------------------------------------------------------------------------
 * Page-aligned code pages for Sv39 SFENCE.VMA and satp-write invalidation
 * -------------------------------------------------------------------------- */
    .section .text.fbc_page_branch, "ax", @progbits
    .balign 4096
    .globl fbc_page_branch
fbc_page_branch:
    li   a0, 0                  /* 0x00 */
    addi a0, a0, 1              /* 0x04 */
    addi a0, a0, 2              /* 0x08 */
    addi a0, a0, 4              /* 0x0C */
    beq  x0, x0, 1f             /* 0x10: always taken, skips +8 and +16 */
    addi a0, a0, 8              /* 0x14 */
    addi a0, a0, 16             /* 0x18 */
1:  addi a0, a0, 32             /* 0x1C */
    ret                         /* 0x20 */
    .org 0x1000 - 4
    .word 0x00000013

    .section .text.fbc_page_alu, "ax", @progbits
    .balign 4096
    .globl fbc_page_alu
fbc_page_alu:
    li   a0, 0                  /* 0x00 */
    addi a0, a0, 1              /* 0x04 */
    addi a0, a0, 2              /* 0x08 */
    addi a0, a0, 4              /* 0x0C */
    addi a0, a0, 64             /* 0x10: plain ALU where page_branch had beq */
    addi a0, a0, 8              /* 0x14 */
    addi a0, a0, 16             /* 0x18 */
    addi a0, a0, 32             /* 0x1C */
    ret                         /* 0x20 */
    .org 0x1000 - 4
    .word 0x00000013

/* --------------------------------------------------------------------------
 * Main assembly test routines
 * -------------------------------------------------------------------------- */
    .section .text
    .balign 64

/* Case 1: void fbc_m_trap_case(unsigned long pre_use_stale,
 *                              struct fbc_m_trap_out *out)
 * Uses two identical, 64-byte-aligned bodies (hit vs. miss) so neither site
 * has prior fast-BTB or backing-BTB state and no pre-fence speculative fetch
 * can warm the backing table ahead of the test.
 * Layout of out (8-byte fields):
 *   0: cause, 8: epc, 16: expected_epc, 24: a2, 32: t2,
 *   40: ra_got, 48: expected_ra, 56: cycles
 */
.macro FBC_M_BODY pfx
    .balign 64
    .globl \pfx\()_body
    .globl \pfx\()_fault_ld
    .globl \pfx\()_nop
    .globl \pfx\()_jalr
    .globl \pfx\()_real
    .globl \pfx\()_stale
\pfx\()_body:
    divu t1, s4, s5             /* +0x00 */
    divu t1, t1, s5             /* +0x04 -> 0x00100000 */
\pfx\()_fault_ld:
    ld   a1, 0(t1)              /* +0x08: load access fault */
\pfx\()_nop:
    nop                         /* +0x0C */
\pfx\()_jalr:
    jalr ra, 0(s0)              /* +0x10: resolves early before fault_ld traps */
    j    .                      /* +0x14 */
\pfx\()_real:
    csrr t5, mcycle             /* +0x18: in same 32B line as body (warm in L1I) */
    addi a2, a2, 7              /* +0x1C */
    j    fbc_m_done             /* +0x20 */
    .balign 32
\pfx\()_stale:
    addi t2, t2, 1              /* +0x40: separate line, cannot fall into *_real */
    j    .                      /* +0x44 */
.endm

/* Fill all 64 bits of path history with 0 (35 taken branches to a 16-byte-
 * aligned label where PC[3:2] == 2'b00 -> 70 zero bits shifted in). */
.macro FBC_ZERO_PATH_HIST reg
    li   \reg, 36
    .balign 16
99: addi \reg, \reg, -1
    bnez \reg, 99b
.endm

    .globl fbc_m_trap_case
fbc_m_trap_case:
    addi sp, sp, -112
    sd   ra, 0(sp)
    sd   s0, 8(sp)
    sd   s1, 16(sp)
    sd   s2, 24(sp)
    sd   s3, 32(sp)
    sd   s4, 40(sp)
    sd   s5, 48(sp)
    sd   s6, 56(sp)
    sd   s7, 64(sp)
    sd   s8, 72(sp)
    sd   s9, 80(sp)
    sd   s10, 88(sp)
    csrr s6, mtvec
    sd   s6, 96(sp)

    mv   s2, a1                 /* s2 = out */
    bnez a0, 1f
    la   s7, fbc_mh_body
    la   s8, fbc_mh_fault_ld
    la   s9, fbc_mh_nop
    la   s10, fbc_mh_jalr
    la   s1, fbc_mh_real
    mv   s0, s1                 /* pre-trap target == real target */
    j    2f
1:  la   s7, fbc_mm_body
    la   s8, fbc_mm_fault_ld
    la   s9, fbc_mm_nop
    la   s10, fbc_mm_jalr
    la   s1, fbc_mm_real
    /* Scrub ITT for fbc_mm_jalr with a neutral target 4 times at the exact
     * same 64-bit path history that post-mret reaches (62 zero bits + 2'b11
     * from jumping to a +0x0C address), then clear the fast BTB so warm resets
     * cannot let ITT override the surviving stale entry with fbc_mm_real. */
    li   s3, 4
    la   s0, fbc_mm_itt_scrub
fbc_mm_itt_loop:
    FBC_ZERO_PATH_HIST t0
    j    fbc_mm_nop             /* fbc_mm_nop is at +0x0C (PC[3:2] == 2'b11) */
fbc_mm_itt_scrub:
    addi s3, s3, -1
    bnez s3, fbc_mm_itt_loop
    fence.i
    la   s0, fbc_mm_stale       /* pre-trap target == stale target */
2:  la   t0, fbc_m_trap_handler
    csrw mtvec, t0
    li   s4, 0x00900000         /* 9 * 0x00100000 (unmapped fault address) */
    li   s5, 3
    li   ra, 0x987
    li   t2, 40
    li   a2, 0
    jr   s7
    j    .

    FBC_M_BODY fbc_mh
    FBC_M_BODY fbc_mm

    .balign 16
fbc_m_trap_handler:
    csrr t0, mcause
    sd   t0, 0(s2)
    csrr t0, mepc
    sd   t0, 8(s2)
    mv   s0, s1                 /* aim jalr at *_real after mret */
    csrw mepc, s9               /* resume at *_nop -> *_jalr */
    li   t0, 0x1800
    csrs mstatus, t0            /* MPP = M (same-side return, no BTB clear) */
    FBC_ZERO_PATH_HIST t0
    j    fbc_m_mret_site        /* match +0x0C (PC[3:2] == 2'b11) of fbc_mm_nop */
    .balign 16
    nop
    nop
    nop
fbc_m_mret_site:
    csrr t6, mcycle             /* start cycle timestamp right before mret */
    mret

fbc_m_done:
    sd   s8, 16(s2)
    sd   a2, 24(s2)
    sd   t2, 32(s2)
    sd   ra, 40(s2)
    addi t0, s10, 4
    sd   t0, 48(s2)
    sub  t5, t5, t6
    sd   t5, 56(s2)

    ld   s6, 96(sp)
    csrw mtvec, s6
    ld   ra, 0(sp)
    ld   s0, 8(sp)
    ld   s1, 16(sp)
    ld   s2, 24(sp)
    ld   s3, 32(sp)
    ld   s4, 40(sp)
    ld   s5, 48(sp)
    ld   s6, 56(sp)
    ld   s7, 64(sp)
    ld   s8, 72(sp)
    ld   s9, 80(sp)
    ld   s10, 88(sp)
    addi sp, sp, 112
    ret

/* Case 2: unsigned long fbc_mstatus_keep_case(void)
 * Returns 1 if the flushed JALR recovers cleanly after a same-side mstatus write.
 */
    .balign 16
    .globl fbc_mstatus_keep_case
    .globl fbc_ms_jalr
    .globl fbc_ms_taken
    .globl fbc_ms_stale
    .globl fbc_ms_real
fbc_mstatus_keep_case:
    addi sp, sp, -64
    sd   ra, 0(sp)
    sd   s0, 8(sp)
    sd   s1, 16(sp)
    sd   s2, 24(sp)
    sd   s3, 32(sp)
    sd   s4, 40(sp)
    sd   s5, 48(sp)

    /* First scrub ITT for fbc_ms_jalr at the exact post-mstatus path history
     * (FBC_ZERO_PATH_HIST + jump to fbc_ms_loop at +0x04) with a neutral target
     * so warm resets cannot override the stale fast-BTB entry on pass 1. */
    li   s3, 4
    li   s4, 0
    li   s5, 3
    la   s0, fbc_ms_itt_scrub
fbc_ms_itt_loop:
    FBC_ZERO_PATH_HIST t0
    j    fbc_ms_loop
fbc_ms_itt_scrub:
    addi s3, s3, -1
    bnez s3, fbc_ms_itt_loop

    /* Run 40 not-taken warmup iterations of bne + fbc_ms_jalr, switching
     * branchlessly to s4 = 8<<56 and s0 = fbc_ms_stale on iteration 40 so the
     * speculative pass enters bne with the exact same 64-bit GHR that was just
     * trained strongly not-taken in both bimodal and TAGE. */
    li   s3, 40
    li   s4, 0
    li   s5, 3
    la   s1, fbc_ms_warmup
    la   s2, fbc_ms_stale
    mv   s0, s1
    li   t2, 40
    li   a2, 0
    j    fbc_ms_loop

    .balign 16
    nop
fbc_ms_loop:                    /* +0x04: PC[3:2] == 2'b01 */
    divu t1, s4, s5
    divu t1, t1, s5             /* warmup/pass1 -> 0 (NT); pass0 -> nonzero (T) */
    bne  t1, zero, fbc_ms_taken
fbc_ms_jalr:
    jalr ra, 0(s0)
    j    .

    .balign 16
    nop
    nop
fbc_ms_warmup:                  /* +0x08: PC[3:2] == 2'b10 (distinct from 2'b00) */
    addi s3, s3, -1             /* 40 -> 39 -> ... -> 1 */
    addi t0, s3, -1
    sltiu t0, t0, 1             /* t0 == 1 iff s3 == 1 (next pass is speculative) */
    slli t1, t0, 56
    slli s4, t1, 3              /* s4 = 8<<56 iff s3 == 1, else 0 */
    neg  t3, t0
    xor  t4, s1, s2
    and  t4, t4, t3
    xor  s0, s1, t4             /* s0 = fbc_ms_stale iff s3 == 1, else fbc_ms_warmup */
    bnez s3, fbc_ms_loop
    j    .

fbc_ms_taken:
    csrr t0, mstatus
    csrw mstatus, t0            /* full flush WITHOUT btb_invalidate */
    li   s4, 0                  /* next pass falls through to fbc_ms_jalr */
    la   s0, fbc_ms_real
    FBC_ZERO_PATH_HIST t0
    j    fbc_ms_loop

fbc_ms_stale:
    addi t2, t2, 1              /* wrong-path target (never commits) */
    j    .

fbc_ms_real:
    addi a2, a2, 7
    la   t0, fbc_ms_jalr
    addi t0, t0, 4
    bne  ra, t0, 1f
    li   t0, 7
    bne  a2, t0, 1f
    li   t0, 40
    bne  t2, t0, 1f
    li   a0, 1
    j    2f
1:  li   a0, 0
2:  ld   ra, 0(sp)
    ld   s0, 8(sp)
    ld   s1, 16(sp)
    ld   s2, 24(sp)
    ld   s3, 32(sp)
    ld   s4, 40(sp)
    ld   s5, 48(sp)
    addi sp, sp, 64
    ret

/* Case 3: unsigned long fbc_flushed_interior_case(void)
 * Wrong-path JALR jumps to odd interior halfword P (fbc_inner_p) of a 32-bit
 * LUI a2 at P - 2, training fast BTB entry P -> P + 4 (fbc_inner_mid). P + 2
 * holds 32-bit addi a0, a0, 80 (0x05050513), whose upper halfword at P + 4 is
 * c.addi a0, 1 (0x0505). Because (P + 4) >> 2 == (P + 2) >> 2, the phantom
 * target window covers pc_reg = P + 2; without walk-past, P + 2 executes early
 * and pc_reg jumps to P + 4, yielding a0 == 98 instead of 97.
 */
    .balign 16
    .globl fbc_flushed_interior_case
    .globl fbc_overlap_entry
    .globl fbc_inner_p
    .globl fbc_inner_mid
fbc_flushed_interior_case:
    addi sp, sp, -64
    sd   ra, 0(sp)
    sd   s0, 8(sp)
    sd   s1, 16(sp)
    sd   s2, 24(sp)
    sd   s3, 32(sp)
    sd   s4, 40(sp)
    sd   s5, 48(sp)

    /* Run 40 not-taken warmup iterations of bne, switching branchlessly to
     * s4 = 8<<56 and s1 = fbc_inner_p on iteration 40 so the test pass enters
     * bne with the exact same 64-bit GHR trained strongly not-taken in TAGE. */
    li   s3, 40
    li   s4, 0
    li   s5, 3
    la   s0, fbc_c3_warmup
    la   s2, fbc_inner_p
    mv   s1, s0
    li   a0, 1
    li   a2, 0

fbc_c3_loop:
    divu t1, s4, s5
    divu t1, t1, s5             /* warmup -> 0 (NT); test pass -> nonzero (T) */
    bne  t1, zero, fbc_overlap_entry
    jalr zero, 0(s1)            /* warmup -> fbc_c3_warmup; test -> odd P */
    j    .

fbc_c3_warmup:
    addi s3, s3, -1             /* 40 -> 39 -> ... -> 1 */
    addi t0, s3, -1
    sltiu t0, t0, 1             /* t0 == 1 iff s3 == 1 */
    slli t1, t0, 56
    slli s4, t1, 3              /* s4 = 8<<56 iff s3 == 1, else 0 */
    neg  t3, t0
    xor  t4, s0, s2
    and  t4, t4, t3
    xor  s1, s0, t4             /* s1 = fbc_inner_p iff s3 == 1, else fbc_c3_warmup */
    bnez s3, fbc_c3_loop
    j    .

    .balign 64
    .option rvc
    c.nop                       /* +0x00 */
fbc_overlap_entry:
    c.nop                       /* +0x02 (P - 4) */
    .half 0x0637                /* +0x04 (P - 2): lo16 of lui a2, ... */
fbc_inner_p:
    c.bnez a0, fbc_inner_mid    /* +0x06 (P, odd): hi16 of lui a2; target = P + 4 */
    .option norvc
    .half 0x0513                /* +0x08 (P + 2): lo16 of addi a0, a0, 80 (0x05050513) */
fbc_inner_mid:
    .half 0x0505                /* +0x0a (P + 4): hi16 of addi a0, a0, 80 (c.addi a0, 1) */
    addi a0, a0, 16             /* +0x0c (P + 6) */
    jal  zero, fbc_inner_check

fbc_inner_check:
    li   t5, 97                 /* 1 + 80 + 16; would be 98 without walk-past */
    bne  a0, t5, 1f
    lhu  t4, 0(s1)
    slli t4, t4, 16
    addiw t4, t4, 0
    bne  a2, t4, 1f
    li   a0, 1
    j    2f
1:  li   a0, 0
2:  ld   ra, 0(sp)
    ld   s0, 8(sp)
    ld   s1, 16(sp)
    ld   s2, 24(sp)
    ld   s3, 32(sp)
    ld   s4, 40(sp)
    ld   s5, 48(sp)
    addi sp, sp, 64
    ret

/* --------------------------------------------------------------------------
 * Case 4: Sv39 S-mode runner and M-mode exit trap handler
 * -------------------------------------------------------------------------- */
    .balign 16
    .globl fbc_sv39_m_trap_handler
fbc_sv39_m_trap_handler:
    csrr t0, mcause
    la   t1, g_fbc_m_cause
    sd   t0, 0(t1)
    csrr t0, mscratch
    csrw mepc, t0
    li   t0, 0x1800
    csrs mstatus, t0            /* MPP = M */
    mret

/* Entered in S-mode via mret with:
 *   s0 = VA_ALIAS, s2 = &PT_L0_A[va_idx], s3 = pte_alu,
 *   s4 = pte_branch, s5 = satp_b (ASID=2, PT_ROOT_B)
 */
    .balign 16
    .globl fbc_sv39_s_entry
fbc_sv39_s_entry:
    /* --- Subcase 4a: SFENCE.VMA without FENCE.I or satp write --- */
    li   s1, 8
1:  jalr ra, 0(s0)              /* trains taken beq at VA_ALIAS + 0x10 */
    addi s1, s1, -1
    bnez s1, 1b
    la   t0, g_fbc_sfence_train
    sd   a0, 0(t0)

    sd   s3, 0(s2)              /* remap VA_ALIAS -> page_alu */
    sfence.vma                  /* NO fence.i, NO satp write */
    jalr ra, 0(s0)
    la   t0, g_fbc_sfence_after
    sd   a0, 0(t0)

    /* --- Subcase 4b: satp write (ASID 1 -> ASID 2) without FENCE.I or SFENCE.VMA --- */
    sd   s4, 0(s2)              /* restore PT_L0_A[VA_ALIAS] -> page_branch */
    sfence.vma
    li   s1, 8
2:  jalr ra, 0(s0)              /* trains taken beq under ASID 1 */
    addi s1, s1, -1
    bnez s1, 2b
    la   t0, g_fbc_satp_train
    sd   a0, 0(t0)

    csrw satp, s5               /* switch to ASID 2 / PT_ROOT_B: NO sfence.vma, NO fence.i */
    jalr ra, 0(s0)
    la   t0, g_fbc_satp_after
    sd   a0, 0(t0)

    ecall                       /* S->M trap back to M-mode caller */
    j    .

    .option pop
