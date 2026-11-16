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

/* Entering at train executes c.j; entering at overlap executes that parcel
 * as the upper half of lui a2. The preceding c.nop can pair with lui.
 * Y and its successor both change a0, and the stale target skips the successor.
 */
    .section .text
    .option push
    .option norelax
    .balign 64
    .global wp_odd_overlap
    .global wp_odd_train
    .global wp_odd_y
    .global wp_odd_stale
    .option norvc
wp_odd_overlap:
    jal zero, 1f
    .half 0x0000
1:
    .option rvc
    c.nop
    .half 0x0637
wp_odd_train:
    c.j wp_odd_stale
    .option norvc
wp_odd_y:
    addi a0, a0, 1
    addi a0, a0, 16
    .option rvc
    c.jr ra
wp_odd_stale:
    .option norvc
    addi a0, a0, 256
    .option rvc
    c.jr ra
    .balign 64
    .global wp_even_overlap
    .global wp_even_train
    .global wp_even_y
    .global wp_even_stale
    .option norvc
wp_even_overlap:
    jal zero, 1f
    addi zero, zero, 0
1:
    .option rvc
    c.nop
    .half 0x0637
wp_even_train:
    c.j wp_even_stale
    .option norvc
wp_even_y:
    addi a0, a0, 1
    addi a0, a0, 16
    .option rvc
    c.jr ra
    c.nop
wp_even_stale:
    .option norvc
    addi a0, a0, 256
    .option rvc
    c.jr ra

    /* Slot-2 redirect at P+2 behind a 32-bit instruction at P-2, with T2 < P. */
    .balign 64
    .global wp_slot2_below_overlap
    .global wp_slot2_below_train
    .global wp_slot2_below_b2_train
    .global wp_slot2_below_stale
    .option norvc
wp_slot2_below_overlap:
    li a3, 0
    addi a0, a0, 1
    jal zero, 1f
wp_slot2_below_t2:
    addi a0, a0, 16
    .option rvc
    c.jr ra
    .balign 64
    .rept 30
    c.nop
    .endr
1:
    c.bnez a3, wp_slot2_below_t2
    .half 0x0637
wp_slot2_below_train:
    c.j wp_slot2_below_stale
wp_slot2_below_b2_train:
    c.j wp_slot2_below_t2
wp_slot2_below_stale:
    .option norvc
    addi a0, a0, 256
    .option rvc
    c.jr ra

    /* Slot-2 redirect at P+2 behind a 32-bit instruction at P-2, with T2 == P (odd P). */
    .balign 64
    .global wp_slot2_at_overlap
    .global wp_slot2_at_train
    .global wp_slot2_at_b2_train
    .global wp_slot2_at_stale
    .option norvc
wp_slot2_at_train:
    addi t2, ra, 0
    la t0, wp_slot2_at_stale
    jal zero, wp_slot2_at_p
wp_slot2_at_b2_train:
    addi t2, ra, 0
    la t0, wp_slot2_at_good
    jal zero, wp_slot2_at_b2
wp_slot2_at_overlap:
    addi t2, ra, 0
    la t0, wp_slot2_at_good
    li a3, 0
    addi a0, a0, 1
    jal zero, 1f
    .balign 64
    .rept 31
    .option rvc
    c.nop
    .endr
1:
    c.bnez a3, wp_slot2_at_good
    .half 0x0637
wp_slot2_at_p:
    c.jalr t0
wp_slot2_at_b2:
    c.j wp_slot2_at_p
wp_slot2_at_good:
    .option norvc
    addi a0, a0, 16
    jalr zero, t2, 0
wp_slot2_at_stale:
    addi a0, a0, 256
    jalr zero, t2, 0
    .option pop
