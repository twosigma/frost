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

# Assembly landmarks for the debug-module benches (Phase 3 M3). The benches
# look up every label below in the ELF symbol table, so the exact instruction
# layout matters:
#
#   bp_target       32-bit addi (software breakpoint site; step +4)
#   bp_target_rvc   c.nop (16-bit software breakpoint site; step +2)
#                   c.nop (step +2)
#                   ret   (step lands on the caller's return address)
#   u_loop          the U-mode loop: bump counter, ecall (u_ecall_site), loop
#   trap_entry      the M-mode trap entry (single-step over an ecall must halt
#                   exactly here)

    .section .text
    .balign 4
    .globl bp_target
    .globl bp_target_rvc
    .type bp_target, @function
bp_target:
    .option push
    .option norvc
    addi    a0, a0, 1
    .option pop
bp_target_rvc:
    c.nop
    c.nop
    ret
    .size bp_target, .-bp_target

    .balign 4
    .globl u_loop
    .globl u_ecall_site
    .globl u_loop_end
    .type u_loop, @function
u_loop:
    la      t0, counter
1:
    ld      t1, 0(t0)
    addi    t1, t1, 1
    sd      t1, 0(t0)
u_ecall_site:
    .option push
    .option norvc
    ecall
    .option pop
    j       1b
u_loop_end:
    .size u_loop, .-u_loop

# Trap entry: save the caller-saved registers, call trap_dispatch(mcause,
# mepc), install the returned mepc, restore, mret. Runs in M-mode on its own
# stack frame (traps arrive from M or from the U loop, both with a valid sp:
# the U loop keeps main's sp).
    .balign 4
    .globl trap_entry
    .type trap_entry, @function
trap_entry:
    addi    sp, sp, -128
    sd      ra, 0(sp)
    sd      t0, 8(sp)
    sd      t1, 16(sp)
    sd      t2, 24(sp)
    sd      a0, 32(sp)
    sd      a1, 40(sp)
    sd      a2, 48(sp)
    sd      a3, 56(sp)
    sd      a4, 64(sp)
    sd      a5, 72(sp)
    sd      a6, 80(sp)
    sd      a7, 88(sp)
    sd      t3, 96(sp)
    sd      t4, 104(sp)
    sd      t5, 112(sp)
    sd      t6, 120(sp)
    csrr    a0, mcause
    csrr    a1, mepc
    call    trap_dispatch
    csrw    mepc, a0
    ld      ra, 0(sp)
    ld      t0, 8(sp)
    ld      t1, 16(sp)
    ld      t2, 24(sp)
    ld      a0, 32(sp)
    ld      a1, 40(sp)
    ld      a2, 48(sp)
    ld      a3, 56(sp)
    ld      a4, 64(sp)
    ld      a5, 72(sp)
    ld      a6, 80(sp)
    ld      a7, 88(sp)
    ld      t3, 96(sp)
    ld      t4, 104(sp)
    ld      t5, 112(sp)
    ld      t6, 120(sp)
    addi    sp, sp, 128
    mret
    .size trap_entry, .-trap_entry
