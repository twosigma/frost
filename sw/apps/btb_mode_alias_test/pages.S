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
 * Code for the bare/Sv39 BTB alias test.
 *
 *   page_branch  a0 = 0 + 1 + 2 + 4, then "beq x0, x0" at +0x10 over the
 *                +8 and +16, then + 32: returns 39
 *   page_alu     the same layout with "addi a0, a0, 64" at +0x10: returns
 *                127, or 103 if fetch follows the other page's taken entry
 *   driver       S-mode call stub (+0x000), M-mode trap handler (+0x100),
 *                and the M-mode train-then-enter routine (+0x200)
 *
 * The driver's mappings swap the two code pages: virtual page_alu runs
 * page_branch and virtual page_branch runs page_alu, while M-mode fetches
 * both at their physical addresses. The code at +0x10 is one fast-BTB index
 * (4); every other branch here sits at an index in another table row. Each
 * page is fully populated so the linker places nothing else in it.
 */

    .option norelax
    .option norvc

    .section .text.btb_alias_page_branch, "ax", @progbits
    .balign 4096
    .globl btb_alias_page_branch
btb_alias_page_branch:
    li   a0, 0                  /* 0x00 */
    addi a0, a0, 1              /* 0x04 */
    addi a0, a0, 2              /* 0x08 */
    addi a0, a0, 4              /* 0x0C */
    beq  x0, x0, 1f             /* 0x10: always taken, to 0x1C */
    addi a0, a0, 8              /* 0x14 */
    addi a0, a0, 16             /* 0x18 */
1:  addi a0, a0, 32             /* 0x1C */
    ret                         /* 0x20 */
    .org 0x1000 - 4
    .word 0x00000013            /* nop: keep the page fully populated */

    .section .text.btb_alias_page_alu, "ax", @progbits
    .balign 4096
    .globl btb_alias_page_alu
btb_alias_page_alu:
    li   a0, 0                  /* 0x00 */
    addi a0, a0, 1              /* 0x04 */
    addi a0, a0, 2              /* 0x08 */
    addi a0, a0, 4              /* 0x0C */
    addi a0, a0, 64             /* 0x10: where the other page has its beq */
    addi a0, a0, 8              /* 0x14 */
    addi a0, a0, 16             /* 0x18 */
    addi a0, a0, 32             /* 0x1C */
    ret                         /* 0x20 */
    .org 0x1000 - 4
    .word 0x00000013

    .section .text.btb_alias_driver, "ax", @progbits
    .balign 4096

    /* S-mode: call the function at s2, s1 times, then ecall with the last
     * result in a0. */
    .globl btb_alias_s_stub
btb_alias_s_stub:
1:  jalr ra, 0(s2)
    addi s1, s1, -1
    bnez s1, 1b
    ecall
    j    .

    /* M-mode trap handler: record mcause and a0 (the stub's result). With
     * g_btb_alias_m_call set, call page_alu at its physical address at once
     * and record its result. Return to the mscratch continuation in M-mode. */
    .org 0x100
    .globl btb_alias_trap_handler
btb_alias_trap_handler:
    csrr t0, mcause
    la   t1, g_btb_alias_cause
    sd   t0, 0(t1)
    la   t1, g_btb_alias_s_result
    sd   a0, 0(t1)
    la   t1, g_btb_alias_m_call
    ld   t2, 0(t1)
    beqz t2, 1f
    la   t0, btb_alias_page_alu
    jalr ra, 0(t0)
    la   t1, g_btb_alias_m_result
    sd   a0, 0(t1)
1:  csrr t0, mscratch
    csrw mepc, t0
    li   t0, 0x1800
    csrs mstatus, t0            /* MPP = M */
    mret

    /* M-mode: call the function at a0, a1 times, at its physical address,
     * and record the last result. Then enter S-mode at the stub (a2) with
     * s2 = a3 and s1 = 1, through mret (a4 = 0) or sret (a4 = 1). The stub's
     * ecall returns to the caller's mscratch continuation. */
    .org 0x200
    .globl btb_alias_m_train_enter
btb_alias_m_train_enter:
    mv   s3, a0
    mv   s4, a1
    mv   s5, a2
    mv   s2, a3
    mv   s6, a4
1:  jalr ra, 0(s3)
    addi s4, s4, -1
    bnez s4, 1b
    la   t1, g_btb_alias_m_result
    sd   a0, 0(t1)
    li   s1, 1
    bnez s6, 2f
    li   t0, 0x1800
    csrc mstatus, t0
    li   t0, 0x0800
    csrs mstatus, t0            /* MPP = S */
    csrw mepc, s5
    mret
2:  li   t0, 0x100
    csrs mstatus, t0            /* SPP = S */
    csrw sepc, s5
    sret
    .org 0x1000 - 4
    .word 0x00000013
