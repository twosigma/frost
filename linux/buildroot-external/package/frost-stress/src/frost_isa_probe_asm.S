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
 * Leaf assembly helpers for frost_isa_probe.
 *
 * Extended register instructions are isolated here under local .option arch
 * blocks so the C driver, startup code, and static C library stay plain
 * RV64GC.
 *
 * struct ext_reg_state layout:
 *   offset  0: vstart (u64)
 *   offset  8: vl     (u64)
 *   offset 16: vtype  (u64)
 *   offset 24: vcsr   (u64)
 *   offset 32: vlenb  (u64)
 *   offset 64: vreg[] (32 * vlenb bytes, 64-byte aligned)
 */

    .text

    .globl isa_probe_first_use_vsetvli
    .type isa_probe_first_use_vsetvli, @function
isa_probe_first_use_vsetvli:
    .option push
    .option arch, +v
    .globl isa_probe_first_use_insn
isa_probe_first_use_insn:
    vsetvli a0, zero, e16, m1, tu, mu
    .option pop
    ret
    .size isa_probe_first_use_vsetvli, .-isa_probe_first_use_vsetvli

    .globl isa_probe_phase2_vsetvli
    .type isa_probe_phase2_vsetvli, @function
isa_probe_phase2_vsetvli:
    .option push
    .option arch, +v
    .globl isa_probe_phase2_insn
isa_probe_phase2_insn:
    vsetvli a0, a0, e32, m1, ta, ma
    .option pop
    ret
    .size isa_probe_phase2_vsetvli, .-isa_probe_phase2_vsetvli

    .globl isa_probe_read_vlenb
    .type isa_probe_read_vlenb, @function
isa_probe_read_vlenb:
    .option push
    .option arch, +v
    csrr a0, vlenb
    .option pop
    ret
    .size isa_probe_read_vlenb, .-isa_probe_read_vlenb

    .globl isa_probe_load_state
    .type isa_probe_load_state, @function
isa_probe_load_state:
    .option push
    .option arch, +v
    csrwi vstart, 0
    csrr t0, vlenb
    slli t1, t0, 3
    addi t2, a0, 64
    vl8re8.v v0, (t2)
    add t2, t2, t1
    vl8re8.v v8, (t2)
    add t2, t2, t1
    vl8re8.v v16, (t2)
    add t2, t2, t1
    vl8re8.v v24, (t2)
    ld t3, 8(a0)
    ld t4, 16(a0)
    vsetvl zero, t3, t4
    ld t3, 24(a0)
    csrw vcsr, t3
    ld t3, 0(a0)
    csrw vstart, t3
    .option pop
    ret
    .size isa_probe_load_state, .-isa_probe_load_state

    .globl isa_probe_dump_state
    .type isa_probe_dump_state, @function
isa_probe_dump_state:
    .option push
    .option arch, +v
    csrr t0, vstart
    csrr t1, vl
    csrr t2, vtype
    csrr t3, vcsr
    csrr t4, vlenb
    sd t0, 0(a0)
    sd t1, 8(a0)
    sd t2, 16(a0)
    sd t3, 24(a0)
    sd t4, 32(a0)
    csrwi vstart, 0
    slli t5, t4, 3
    addi t6, a0, 64
    vs8r.v v0, (t6)
    add t6, t6, t5
    vs8r.v v8, (t6)
    add t6, t6, t5
    vs8r.v v16, (t6)
    add t6, t6, t5
    vs8r.v v24, (t6)
    .option pop
    ret
    .size isa_probe_dump_state, .-isa_probe_dump_state

    .globl isa_probe_rearm_vstart
    .type isa_probe_rearm_vstart, @function
isa_probe_rearm_vstart:
    .option push
    .option arch, +v
    csrw vstart, a0
    .option pop
    ret
    .size isa_probe_rearm_vstart, .-isa_probe_rearm_vstart

/*
 * Scalar spin loop used as a known-PC target for signal, ptrace, and core
 * boundaries without executing any syscall or extended instruction.
 *   a0: ready_out (set to 1 after preceding register loads complete)
 *   a1: stop_in   (loop exits once nonzero)
 */
    .globl isa_probe_spin_until_flag
    .type isa_probe_spin_until_flag, @function
isa_probe_spin_until_flag:
    fence rw, w
    li t0, 1
    sw t0, 0(a0)
    .globl isa_probe_spin_loop
isa_probe_spin_loop:
    lw t1, 0(a1)
    beqz t1, isa_probe_spin_loop
    .globl isa_probe_spin_end
isa_probe_spin_end:
    fence r, rw
    ret
    .size isa_probe_spin_until_flag, .-isa_probe_spin_until_flag
