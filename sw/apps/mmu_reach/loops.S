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

/* The timing loops use registers. sscratch identifies trace windows. */
    .option norvc
    .text
    .global data_chain
/* a0 = start, a1 = warm loads, a2 = timed groups of eight, a3 = trace id. */
data_chain:
    li t0, 0x1800
    csrc mstatus, t0
    li t0, 0x20800
    csrs mstatus, t0
1:  ld a0, 0(a0)
    addi a1, a1, -1
    bnez a1, 1b
    csrw sscratch, a3
    rdcycle t1
2:  .rept 8
    ld a0, 0(a0)
    .endr
    addi a2, a2, -1
    bnez a2, 2b
    rdcycle t2
    csrw sscratch, zero
    li t0, 0x20000
    csrc mstatus, t0
    mv a1, a0
    sub a0, t2, t1
    ret

    .global context_chain
/* a0/a1 = roots, a2 = start, a3 = pages, a4 = switches, a5 = trace id.
 * Return cycles in a0 and sum of per-context signatures in a1. */
context_chain:
    li t0, 0x1800
    csrc mstatus, t0
    li t0, 0x20800
    csrs mstatus, t0
    li a6, 0
    csrw sscratch, a5
    rdcycle t1
1:  csrw satp, a0
    sfence.vma
    mv t3, a2
    mv t4, a3
    beqz t4, 3f
2:  ld t3, 0(t3)
    addi t4, t4, -1
    bnez t4, 2b
    ld t5, 8(t3)
    add a6, a6, t5
3:  mv t5, a0
    mv a0, a1
    mv a1, t5
    addi a4, a4, -1
    bnez a4, 1b
    rdcycle t2
    csrw sscratch, zero
    li t0, 0x20000
    csrc mstatus, t0
    sub a0, t2, t1
    mv a1, a6
    ret

    .global instruction_chain
/* a0 = entry, a1 = page visits, a2 = trace id; trap returns elapsed cycles. */
instruction_chain:
    andi a3, a2, 255
    addi a3, a3, -1
    li t0, 4128
    mul a3, a3, t0
    add a3, a3, a0
    addi a3, a3, 20
    la t0, 1f
    csrw mscratch, t0
    la t0, chain_trap
    csrw mtvec, t0
    csrw mepc, a0
    li t0, 0x1800
    csrc mstatus, t0
    li t0, 0x800
    csrs mstatus, t0
    li t0, 1
    csrs mcounteren, t0
    mv t3, a1
    csrw sscratch, a2
    rdcycle t4
    mret
1:  csrw sscratch, zero
    ret
chain_trap:
    csrr t0, mcause
    li t1, 9
    bne t0, t1, 3f
    bnez t3, 3f
    csrr t0, mepc
    beq t0, a3, 2f
3:
    li a0, -1
2:  csrr t0, mscratch
    csrw mepc, t0
    li t0, 0x1800
    csrs mstatus, t0
    mret

    .global validate_chain
/* a0 = start, a1 = stride, a2 = pages, a3 = first signature. Returns a boolean. */
validate_chain:
    li t0, 0x1800
    csrc mstatus, t0
    li t0, 0x20800
    csrs mstatus, t0
    mv t1, a0
    mv t2, a0
1:  ld t3, 0(t1)
    ld t4, 8(t1)
    bne t4, a3, 3f
    addi a3, a3, 1
    addi a2, a2, -1
    beqz a2, 2f
    add t2, t2, a1
    bne t3, t2, 3f
    mv t1, t3
    j 1b
2:  bne t3, a0, 3f
    li a0, 1
    j 4f
3:  li a0, 0
4:  li t0, 0x20000
    csrc mstatus, t0
    ret
