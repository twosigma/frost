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

/* Timing loops for resident working sets under Sv39 data translation. Code
 * runs in M-mode and MPRV with MPP=S translates the data accesses. An MPRV
 * change empties the TLBs, so each loop warms, sweeps and times inside one
 * translated window. The sweep loads once from each of a3 superpages, 2 MiB
 * apart: those translations miss every 4 KiB structure, install in the DTLB
 * and push the warmed 4 KiB pages out of it, as kernel traffic does between
 * a program's time slices. Only t and a registers are used. */
    .option norvc
    .text

.macro TRANSLATE_DATA
    li t0, 0x1800
    csrc mstatus, t0
    li t0, 0x20800
    csrs mstatus, t0
.endm

.macro UNTRANSLATE_DATA
    li t0, 0x20000
    csrc mstatus, t0
.endm

/* Load once from each of \count superpages starting at \base. */
.macro SWEEP base, count
    mv t3, \base
    mv t4, \count
    li t5, 0x200000
    beqz t4, 2f
1:  ld t1, 0(t3)
    add t3, t3, t5
    addi t4, t4, -1
    bnez t4, 1b
2:
.endm

/* The DCPerf pointer-chase loop: index = base[index], with the index stored
 * back to the state block every hop. a0 = state, \hops > 0. */
.macro CHASE hops
    ld t2, 0(a0)
    ld t3, 24(a0)
    mv t4, \hops
1:  slli t3, t3, 3
    add t3, t3, t2
    ld t3, 0(t3)
    addi t4, t4, -1
    sd t3, 24(a0)
    bnez t4, 1b
.endm

    .global resident_chase
/* a0 = state (base VA at 0, index at 24), a1 = warm hops, a2 = timed hops,
 * a3 = sweep superpages, a4 = first sweep VA, a5 = trace id for sscratch.
 * Returns the timed cycles. */
resident_chase:
    TRANSLATE_DATA
    CHASE a1
    SWEEP a4, a3
    csrw sscratch, a5
    rdcycle a6
    CHASE a2
    rdcycle a7
    csrw sscratch, zero
    UNTRANSLATE_DATA
    sub a0, a7, a6
    ret

    .global resident_scan
/* a0 = first scanned VA, a1 = lines, a2 = stack page VA, a3 = sweep
 * superpages, a4 = first sweep VA, a5 = task block VA, a6 = cursor block VA,
 * a7 = trace id for sscratch. Each line calls a copy routine that reads one
 * dword of the line into the stack page between an increment and a decrement
 * of a task counter, then updates a cursor block and a stack counter, as a
 * kernel memory patrol does. Returns the timed cycles. */
resident_scan:
    mv t6, a7
    mv a7, ra
    TRANSLATE_DATA
    ld t1, 0(a0)
    ld t1, 0(a5)
    ld t1, 0(a6)
    sd a1, 16(a2)
    SWEEP a4, a3
    csrw sscratch, t6
    rdcycle t5
    mv a4, a1
1:  jal ra, copy_dword
    ld t3, 16(a2)
    addi t3, t3, -1
    sd t3, 16(a2)
    addi a0, a0, 64
    sd a0, 0(a6)
    ld t4, 8(a6)
    addi t4, t4, 1
    sd t4, 8(a6)
    addi a4, a4, -1
    bnez a4, 1b
    rdcycle t6
    csrw sscratch, zero
    UNTRANSLATE_DATA
    sub a0, t6, t5
    jr a7

/* a0 = source VA, a2 = stack page VA, a5 = task block VA. */
copy_dword:
    ld t1, 0(a5)
    addi t1, t1, 1
    sd t1, 0(a5)
    ld t2, 0(a0)
    sd t2, 8(a2)
    ld t1, 0(a5)
    addi t1, t1, -1
    sd t1, 0(a5)
    ret
