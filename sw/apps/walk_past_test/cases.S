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
    .option pop
