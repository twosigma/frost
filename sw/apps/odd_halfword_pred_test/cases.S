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
 * Pinned-alignment instruction sequences for odd_halfword_pred_test:
 *   1a: Odd-halfword 32-bit loop branch (bne at +0x06) looked up by slot 1.
 *   1b: Untaken 32-bit branch (+0x00) then even jump (+0x04) to an odd target
 *       (+0x0a) holding a 32-bit ALU instruction, followed by an odd-halfword
 *       32-bit loop branch (+0x12).
 *   2:  Repeated odd-halfword 32-bit call (jal ra at +0x06) and compressed
 *       return to odd link address (+0x0a).
 *   3a: Spanning 32-bit call (+0x1e) and 32-bit loop branch (+0x3e) straddling
 *       32-byte cache-line boundaries.
 *   3b: Static 4 KiB pages for Sv39 page-end spanning call at offset +0xffe.
 *   4a: Overlapping 32-bit lui at P-2 with a compressed c.j trained at odd P.
 *   4b: Overlapping 32-bit lui at P-2 with a native 32-bit bne trained at odd P.
 */

    .option norelax
    .section .text

/* --------------------------------------------------------------------------
 * Case 1a: slot-1 fast-BTB lookup of a 32-bit loop branch at +0x06.
 * A 2-byte compressed op at +0x00 pairs with a 4-byte native op at +0x02,
 * advancing both o_pc and o_pc_reg by +6 onto +0x06.
 * -------------------------------------------------------------------------- */
    .balign 32
    .global ohp_case1a_loop
    .global ohp_case1a_head
    .global ohp_case1a_bne
    .type ohp_case1a_loop, @function
ohp_case1a_loop:
    .option push
    .option norelax
    .option rvc
    c.li    a1, 0
    c.li    t0, 0
    .balign 32
ohp_case1a_head:
    .option rvc
    c.addi  a1, 1
    .option norvc
    addi    t0, t0, 3
ohp_case1a_bne:
    bne     a1, a0, ohp_case1a_head
    .option rvc
    slli    a1, a1, 16
    or      a0, a1, t0
    c.jr    ra
    .option pop

/* --------------------------------------------------------------------------
 * Case 1b: untaken 32-bit branch at +0x00 establishes a 4-byte fetch lead so
 * the even jump (+0x04) pends to odd target (+0x0a) holding a 32-bit target
 * instruction, plus an odd-halfword 32-bit loop branch at +0x12.
 * -------------------------------------------------------------------------- */
    .balign 32
    .global ohp_case1b_loop
    .global ohp_case1b_head
    .global ohp_case1b_target
    .global ohp_case1b_bne
    .type ohp_case1b_loop, @function
ohp_case1b_loop:
    .option push
    .option norelax
    .option rvc
    c.li    a1, 0
    c.li    t0, 0
    .balign 32
ohp_case1b_head:
    .option norvc
    beq     x0, a0, 9f
    jal     x0, ohp_case1b_target
    .half   0x0000
ohp_case1b_target:
    addi    a1, a1, 1
    addi    t0, t0, 5
ohp_case1b_bne:
    bne     a1, a0, ohp_case1b_head
9:
    .option rvc
    slli    a1, a1, 16
    or      a0, a1, t0
    c.jr    ra
    .option pop

/* --------------------------------------------------------------------------
 * Case 2: repeated odd-halfword 32-bit jal ra (+0x06) with return to +0x0a.
 * -------------------------------------------------------------------------- */
    .balign 32
ohp_case2_callee:
    .option push
    .option norelax
    .option norvc
    addi    t0, t0, 7
    .option rvc
    c.jr    ra
    .option pop

    .balign 32
    .global ohp_case2_loop
    .global ohp_case2_head
    .global ohp_case2_call
    .global ohp_case2_bne
    .type ohp_case2_loop, @function
ohp_case2_loop:
    .option push
    .option norelax
    .option rvc
    mv      t2, ra
    c.li    a1, 0
    c.li    t0, 0
    .balign 32
ohp_case2_head:
    .option rvc
    c.addi  a1, 1
    .option norvc
    addi    t0, t0, 1
ohp_case2_call:
    jal     ra, ohp_case2_callee
    addi    x0, x0, 0
ohp_case2_bne:
    bne     a1, a0, ohp_case2_head
    .option rvc
    mv      ra, t2
    slli    a1, a1, 16
    or      a0, a1, t0
    c.jr    ra
    .option pop

/* --------------------------------------------------------------------------
 * Case 3a: 32-bit call at +0x1e and 32-bit loop branch at +0x3e, each
 * spanning a 32-byte cache-line boundary.
 * -------------------------------------------------------------------------- */
    .balign 64
ohp_case3a_callee:
    .option push
    .option norelax
    .option norvc
    addi    t0, t0, 9
    .option rvc
    c.jr    ra
    .option pop

    .balign 64
    .global ohp_case3a_line_end
    .global ohp_case3a_base
    .global ohp_case3a_call
    .global ohp_case3a_bne
    .type ohp_case3a_line_end, @function
ohp_case3a_line_end:
    .option push
    .option norelax
    .option rvc
    mv      t2, ra
    c.li    a1, 0
    c.li    t0, 0
    .balign 64
ohp_case3a_base:
    .rept 11
    c.nop
    .endr
    c.j     1f
1:
    .option rvc
    c.addi  a1, 1
    .option norvc
    addi    t0, t0, 2
ohp_case3a_call:
    jal     ra, ohp_case3a_callee
    .rept 5
    addi    x0, x0, 0
    .endr
    .option rvc
    c.nop
    c.addi  t0, 1
    .option norvc
    addi    t0, t0, 1
ohp_case3a_bne:
    bne     a1, a0, 1b
    .option rvc
    mv      ra, t2
    slli    a1, a1, 16
    or      a0, a1, t0
    c.jr    ra
    .option pop

/* --------------------------------------------------------------------------
 * Case 4a: overlapping 32-bit lui at P-2 (+0x08) with compressed c.j at P
 * (+0x0a).
 *   [+0x08..+0x09] = 0x0637
 *   [+0x0a..+0x0b] = 0xa019  (c.j +6 -> +0x10)
 *   Together from +0x08: 0xa0190637 = lui a2, 0xa0190.
 * -------------------------------------------------------------------------- */
    .balign 64
    .global ohp_case4a_overlap
    .global ohp_case4a_train
ohp_case4a_overlap:
    .option push
    .option norelax
    .option norvc
    jal     x0, 1f
    .half   0x0000
1:
    .option rvc
    c.beqz  a5, 3f
    .half   0x0637
ohp_case4a_train:
    .half   0xa019
    .option norvc
    addi    a2, a2, 0x55
3:
    .option rvc
    mv      a0, a2
    c.jr    ra
    .option pop

/* --------------------------------------------------------------------------
 * Case 4b: overlapping 32-bit lui at P-2 (+0x08) with native 32-bit bne at P
 * (+0x0a).
 *   [+0x08..+0x09] = 0x0637
 *   [+0x0a..+0x0b] = 0x1463  (low half of 0x00011463 = bne sp, zero, +8)
 *   [+0x0c..+0x0d] = 0x0001  (high half of bne; c.nop when entered at +0x0c)
 *   Together from +0x08: 0x14630637 = lui a2, 0x14630.
 * -------------------------------------------------------------------------- */
    .balign 64
    .global ohp_case4b_overlap
    .global ohp_case4b_train
ohp_case4b_overlap:
    .option push
    .option norelax
    .option norvc
    jal     x0, 1f
    .half   0x0000
1:
    .option rvc
    c.beqz  a5, 3f
    .half   0x0637
ohp_case4b_train:
    .half   0x1463
    .half   0x0001
    .option norvc
    addi    a2, a2, 0x55
3:
    .option rvc
    mv      a0, a2
    c.jr    ra
    .option pop

/* --------------------------------------------------------------------------
 * Case 4c: overlapping 32-bit lui at odd P-2 (+0x0a) with compressed c.j at
 * even P (+0x0c) targeting an odd halfword (+0x12, allow_cross = 0).
 *   [+0x0a..+0x0b] = 0x0637
 *   [+0x0c..+0x0d] = 0xa019  (c.j +6 -> +0x12)
 *   Together from +0x0a: 0xa0190637 = lui a2, 0xa0190.
 * -------------------------------------------------------------------------- */
    .balign 64
    .global ohp_case4c_overlap
    .global ohp_case4c_train
ohp_case4c_overlap:
    .option push
    .option norelax
    .option norvc
    jal     x0, 1f
    addi    x0, x0, 0
1:
    .option rvc
    c.beqz  a5, 3f
    .half   0x0637
ohp_case4c_train:
    .half   0xa019
    .option norvc
    addi    a2, a2, 0x55
3:
    .option rvc
    mv      a0, a2
    c.jr    ra
    .option pop

/* --------------------------------------------------------------------------
 * Case 3b: static 4 KiB Sv39 pages for page-end spanning call at +0xffe.
 *   ohp_page_caller: S-mode driver (+0x000), trampoline (+0x0c0), and S-mode
 *                    page-fault handler (+0x200).
 *   ohp_page0:       +0xfe8 jal to +0xff0 (4-byte fetch lead); +0xffe low half of jal ra.
 *   ohp_page1:       +0x000 high half of jal ra; +0x002 link return path;
 *                    +0x010 callee.
 *   ohp_page_evict:  +0x100 TLB-eviction target (jr t6).
 * -------------------------------------------------------------------------- */
    .balign 4096
    .global ohp_page_caller
ohp_page_caller:
    .option push
    .option norelax
    .option norvc
0:
    ld      s1, 0(a5)
    ld      s3, 40(a5)
    li      a1, 0
    li      a2, 0
    li      a3, 0
1:
    /* First three training calls take t5/t3 with t4=0 so TAGE trains bne t4
     * not-taken under (GHR, T, T); the remaining five take t1=0, t4=0 so TAGE
     * trains bne t5 not-taken under the same saturated GHR. */
    sltiu   t1, s3, 6
    xori    t1, t1, 1
    li      t4, 0
    jal     ra, ohp_inner_tramp
    addi    s3, s3, -1
    bnez    s3, 1b

    /* Unmap VA_PAGE1 while remaining in S-mode so fast-BTB state stays live,
     * and read back the cleared PTE so it sits in L1D for the page-table walk. */
    ld      t0, 8(a5)
    sd      zero, 0(t0)
    fence   rw, rw
    ld      zero, 0(t0)

    /* Evict VA_PAGE1 from ITLB and L2TLB without sfence.vma or privilege switches.
     * Under .option norvc: auipc (4B) + addi (4B) + jalr (4B) = +12 bytes to 2f. */
    ld      t1, 24(a5)
    ld      t2, 32(a5)
    li      t3, 0x80000
    auipc   t6, 0
    addi    t6, t6, 12
3:
    jalr    x0, 0(t1)
2:
    add     t1, t1, t3
    addi    t2, t2, -1
    bnez    t2, 3b

    /* Call across the page boundary: P predicts in IF, faults on VA_PAGE1,
     * repairs, retries, and returns through RAS. */
    li      t1, 1
    li      t4, 1
    jal     ra, ohp_inner_tramp
    csrr    a4, hpmcounter4
    sub     a4, a4, t5
    sd      a1, 80(a5)
    sd      a3, 88(a5)
    sd      a4, 96(a5)
    ecall

    .org 0b + 0x0c0
ohp_inner_tramp:
    mv      s2, ra
    /* Saturate the 128-bit branch-history register so training and fault calls
     * enter ohp_page0 with identical direction history across reset runs. */
    li      t0, 132
7:
    addi    t0, t0, -1
    bnez    t0, 7b
    jalr    x0, 0(s1)

    .org 0b + 0x200
ohp_s_page_fault_handler:
    ld      t0, 48(a5)
    bnez    t0, 9f
    addi    t0, t0, 1
    sd      t0, 48(a5)
    csrr    t1, scause
    sd      t1, 56(a5)
    csrr    t1, sepc
    sd      t1, 64(a5)
    csrr    t1, stval
    sd      t1, 72(a5)
    ld      t1, 8(a5)
    ld      t2, 16(a5)
    sd      t2, 0(t1)
    fence   rw, rw
    sret
9:
    ecall

    .org 0b + 4096
    .option pop

    .balign 4096
    .global ohp_page0
    .global ohp_page0_span_jal
    .global ohp_page0_end
ohp_page0:
    .option push
    .option norelax
    .option norvc
0:
    /* Two mul-paced untaken-during-training branches warm immu's fault memo on
     * VA_PAGE1 (expiry period 64 clocks) even under DDR PTW latency, then a
     * short ready-operand branch at 3f lets speculative fetch latch immu's
     * crossing key at +0xffe from the warm memo and redirects to 4f (+0xffa)
     * before fetch leaves VA_PAGE0, so +0xffa -> +0xffe reaches +0xffe with
     * o_pa_valid high and o_fault1 set to exercise the slot-1 BTB fault veto. */
    .org 0b + 0xfb0
    addi    x0, x0, 0
    ori     t6, zero, 3
    mul     t5, t1, t6
    mul     t5, t5, t6
    mul     t5, t5, t6
    mul     t5, t5, t6
    mul     t5, t5, t6
    bne     t5, zero, 2f
2:
    mul     t3, t1, t6
    mul     t3, t3, t6
    mul     t3, t3, t6
    mul     t3, t3, t6
    mul     t3, t3, t6
    bne     t3, zero, 3f
3:
    .option rvc
    c.nop
    .option norvc
    bne     t4, zero, 4f
    addi    x0, x0, 0
    addi    x0, x0, 0
    addi    x0, x0, 0
4:
    addi    a1, a1, 1
ohp_page0_span_jal:
    /* 0x012000ef = jal ra, +18 (targets VA_PAGE1 + 0x010, link VA_PAGE1 + 0x002) */
    .half   0x00ef
ohp_page0_end:
    .option pop

    .balign 4096
    .global ohp_page1
ohp_page1:
    .option push
    .option norelax
0:
    .half   0x0120
    /* Link return address P + 4 = VA_PAGE1 + 0x002 */
    .option norvc
    mv      ra, s2
    csrr    t5, hpmcounter4
    .option rvc
    c.jr    ra

    .org 0b + 0x010
    .option norvc
    addi    a3, a3, 11
    .option rvc
    c.jr    ra

    .org 0b + 4096
    .option pop

    .balign 4096
    .global ohp_page_evict
ohp_page_evict:
    .option push
    .option norelax
    .option norvc
0:
    .org 0b + 0x100
    addi    a2, a2, 1
    jalr    x0, 0(t6)
    .org 0b + 4096
    .option pop

    .balign 16
    .global ohp_enter_s_driver
    .type ohp_enter_s_driver, @function
ohp_enter_s_driver:
    .option push
    .option norelax
    addi    sp, sp, -32
    sd      ra, 0(sp)
    sd      s1, 8(sp)
    sd      s2, 16(sp)
    sd      s3, 24(sp)
    mv      a5, a1
    la      t0, 1f
    csrw    mscratch, t0
    li      t0, 0x1800
    csrc    mstatus, t0
    li      t0, 0x0800
    csrs    mstatus, t0
    csrw    mepc, a0
    mret
1:
    ld      ra, 0(sp)
    ld      s1, 8(sp)
    ld      s2, 16(sp)
    ld      s3, 24(sp)
    addi    sp, sp, 32
    ret
    .option pop

    .balign 16
    .global ohp_m_trap_handler
    .type ohp_m_trap_handler, @function
ohp_m_trap_handler:
    .option push
    .option norelax
    csrr    t0, mcause
    li      t1, 12
    bne     t0, t1, 2f
    ld      t1, 48(a5)
    bnez    t1, 2f
    addi    t1, t1, 1
    sd      t1, 48(a5)
    sd      t0, 56(a5)
    csrr    t1, mepc
    sd      t1, 64(a5)
    csrr    t1, mtval
    sd      t1, 72(a5)
    ld      t1, 8(a5)
    ld      t2, 16(a5)
    sd      t2, 0(t1)
    sfence.vma
    mret
2:
    sd      t0, 104(a5)
    csrr    t0, mscratch
    csrw    mepc, t0
    li      t0, 0x1800
    csrs    mstatus, t0
    mret
    .option pop
