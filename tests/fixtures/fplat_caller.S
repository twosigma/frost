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

/* Check the callee-saved FP registers across the independent throughput loops. */
    .section .text
    .globl main
main:
    addi sp, sp, -112
    sd ra, 96(sp)
    .set slot, 0
    .irp r, fs0,fs1,fs2,fs3,fs4,fs5,fs6,fs7,fs8,fs9,fs10,fs11
        fsd \r, slot(sp)
        .set slot, slot + 8
    .endr
    li t0, 0x0123456789abcdef
    .irp r, fs0,fs1,fs2,fs3,fs4,fs5,fs6,fs7,fs8,fs9,fs10,fs11
        fmv.d.x \r, t0
    .endr
    .irp fn, fadd_thr_s,fadd_thr_d,fmul_thr_s,fmul_thr_d,fmadd_thr_s,fmadd_thr_d
        li a0, 1
        la a1, constants
        li a2, 0
        call \fn
        li t0, 0x0123456789abcdef
        .irp r, fs0,fs1,fs2,fs3,fs4,fs5,fs6,fs7,fs8,fs9,fs10,fs11
            fmv.x.d t1, \r
            bne t1, t0, .Lfailed
        .endr
    .endr
    li a0, 0
    j .Lreturn
.Lfailed:
    li a0, 1
.Lreturn:
    .set slot, 0
    .irp r, fs0,fs1,fs2,fs3,fs4,fs5,fs6,fs7,fs8,fs9,fs10,fs11
        fld \r, slot(sp)
        .set slot, slot + 8
    .endr
    ld ra, 96(sp)
    addi sp, sp, 112
    ret

    .section .rodata
    .balign 8
constants:
    .rept 16
        .dword 0x3ff0000000000000
    .endr
    .rept 16
        .word 0x3f800000
    .endr
