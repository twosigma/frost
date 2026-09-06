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

// S-mode payload entry and trap plumbing for the OpenSBI smoke test.
//
// fw_jump enters _start in S-mode with a0 = hart id, a1 = DTB, satp = 0 and
// sstatus.SIE = 0. The trap entry below is the only stvec target: it keeps the
// S stack pointer in sscratch while U-mode code runs (the usual swap-on-entry
// idiom), saves the full integer frame, and hands it to handle_trap() in C.
// handle_trap returns 0 to sret back to the frame, or 1 to unwind to the
// run_in_umode() caller with the frame's a0 as the return value.

    .section .init, "ax", @progbits
    .option push
    .option norelax
    .globl _start
_start:
    la      sp, _stack_top
    la      gp, __global_pointer$
    mv      s0, a0
    mv      s1, a1
    // Zero .sbss/.bss (contiguous by the linker script; the gap between them
    // is zeroed too).
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       1b
2:  la      t0, trap_entry
    csrw    stvec, t0
    // sscratch = 0 while running in S-mode (see trap_entry).
    csrw    sscratch, zero
    mv      a0, s0
    mv      a1, s1
    call    main
3:  wfi
    j       3b
    .option pop

// Trap frame layout (bytes): x1..x31 at 8*(n-1), then sepc, scause, stval,
// sstatus. FRAME_BYTES keeps 16-byte stack alignment.
#define FRAME_BYTES 288
#define REG(n) (8 * ((n) - 1))
#define F_SEPC 248
#define F_SCAUSE 256
#define F_STVAL 264
#define F_SSTATUS 272

    .section .text
    .align 4
    .globl trap_entry
trap_entry:
    // sscratch holds the S stack pointer while U runs, and 0 while S runs.
    csrrw   sp, sscratch, sp
    bnez    sp, 1f
    csrr    sp, sscratch            // trapped from S: keep the S stack
1:  addi    sp, sp, -FRAME_BYTES
    sd      x1, REG(1)(sp)
    // x2 (the trapping sp) is recovered from sscratch below.
    sd      x3, REG(3)(sp)
    sd      x4, REG(4)(sp)
    sd      x5, REG(5)(sp)
    sd      x6, REG(6)(sp)
    sd      x7, REG(7)(sp)
    sd      x8, REG(8)(sp)
    sd      x9, REG(9)(sp)
    sd      x10, REG(10)(sp)
    sd      x11, REG(11)(sp)
    sd      x12, REG(12)(sp)
    sd      x13, REG(13)(sp)
    sd      x14, REG(14)(sp)
    sd      x15, REG(15)(sp)
    sd      x16, REG(16)(sp)
    sd      x17, REG(17)(sp)
    sd      x18, REG(18)(sp)
    sd      x19, REG(19)(sp)
    sd      x20, REG(20)(sp)
    sd      x21, REG(21)(sp)
    sd      x22, REG(22)(sp)
    sd      x23, REG(23)(sp)
    sd      x24, REG(24)(sp)
    sd      x25, REG(25)(sp)
    sd      x26, REG(26)(sp)
    sd      x27, REG(27)(sp)
    sd      x28, REG(28)(sp)
    sd      x29, REG(29)(sp)
    sd      x30, REG(30)(sp)
    sd      x31, REG(31)(sp)
    csrrw   t0, sscratch, zero      // t0 = trapping sp (U sp, or the S sp)
    sd      t0, REG(2)(sp)
    csrr    t1, sepc
    sd      t1, F_SEPC(sp)
    csrr    t1, scause
    sd      t1, F_SCAUSE(sp)
    csrr    t1, stval
    sd      t1, F_STVAL(sp)
    csrr    t1, sstatus
    sd      t1, F_SSTATUS(sp)
    mv      a0, sp
    call    handle_trap
    bnez    a0, unwind_to_s
    ld      t1, F_SEPC(sp)
    csrw    sepc, t1
    ld      t1, F_SSTATUS(sp)
    csrw    sstatus, t1
    // Returning to U: park the S stack pointer in sscratch again.
    andi    t2, t1, 0x100           // SPP
    bnez    t2, 2f
    addi    t3, sp, FRAME_BYTES
    csrw    sscratch, t3
2:  ld      x1, REG(1)(sp)
    ld      x3, REG(3)(sp)
    ld      x4, REG(4)(sp)
    ld      x5, REG(5)(sp)
    ld      x6, REG(6)(sp)
    ld      x7, REG(7)(sp)
    ld      x8, REG(8)(sp)
    ld      x9, REG(9)(sp)
    ld      x10, REG(10)(sp)
    ld      x11, REG(11)(sp)
    ld      x12, REG(12)(sp)
    ld      x13, REG(13)(sp)
    ld      x14, REG(14)(sp)
    ld      x15, REG(15)(sp)
    ld      x16, REG(16)(sp)
    ld      x17, REG(17)(sp)
    ld      x18, REG(18)(sp)
    ld      x19, REG(19)(sp)
    ld      x20, REG(20)(sp)
    ld      x21, REG(21)(sp)
    ld      x22, REG(22)(sp)
    ld      x23, REG(23)(sp)
    ld      x24, REG(24)(sp)
    ld      x25, REG(25)(sp)
    ld      x26, REG(26)(sp)
    ld      x27, REG(27)(sp)
    ld      x28, REG(28)(sp)
    ld      x29, REG(29)(sp)
    ld      x30, REG(30)(sp)
    ld      x31, REG(31)(sp)
    ld      x2, REG(2)(sp)
    sret

// U-mode code finished with an ecall: return to run_in_umode()'s caller on
// the S stack it saved, with the frame's a0 as the result.
unwind_to_s:
    ld      a0, REG(10)(sp)
    la      t0, g_umode_saved_sp
    ld      sp, 0(t0)
    csrw    sscratch, zero
    j       run_in_umode_return

// unsigned long run_in_umode(unsigned long fn_va, unsigned long arg,
//                            unsigned long ustack_va)
// Runs fn(arg) in U-mode on the given stack; fn ends with an ecall whose a0
// becomes this function's return value (the ecall lands in trap_entry above).
    .globl run_in_umode
run_in_umode:
    addi    sp, sp, -112
    sd      ra, 0(sp)
    sd      s0, 8(sp)
    sd      s1, 16(sp)
    sd      s2, 24(sp)
    sd      s3, 32(sp)
    sd      s4, 40(sp)
    sd      s5, 48(sp)
    sd      s6, 56(sp)
    sd      s7, 64(sp)
    sd      s8, 72(sp)
    sd      s9, 80(sp)
    sd      s10, 88(sp)
    sd      s11, 96(sp)
    la      t0, g_umode_saved_sp
    sd      sp, 0(t0)
    csrw    sepc, a0
    li      t0, 0x120               // SPP=0 (U) and SPIE=0: interrupts stay off in U
    csrc    sstatus, t0
    csrw    sscratch, sp            // S stack for the trap entry while U runs
    mv      sp, a2
    mv      a0, a1
    sret
run_in_umode_return:
    ld      ra, 0(sp)
    ld      s0, 8(sp)
    ld      s1, 16(sp)
    ld      s2, 24(sp)
    ld      s3, 32(sp)
    ld      s4, 40(sp)
    ld      s5, 48(sp)
    ld      s6, 56(sp)
    ld      s7, 64(sp)
    ld      s8, 72(sp)
    ld      s9, 80(sp)
    ld      s10, 88(sp)
    ld      s11, 96(sp)
    addi    sp, sp, 112
    ret

    .section .bss
    .align 3
    .globl g_umode_saved_sp
g_umode_saved_sp:
    .dword 0
