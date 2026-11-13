//    Copyright 2026 Two Sigma Open Source, LLC
//
//    Licensed under the Apache License, Version 2.0 (the "License");
//    you may not use this file except in compliance with the License.
//    You may obtain a copy of the License at
//
//        http://www.apache.org/licenses/LICENSE-2.0
//
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS,
//    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//    See the License for the specific language governing permissions and
//    limitations under the License.

// C-library style string and memory routines in the vector extension, the
// shape glibc and musl select once vectors are advertised. All use e8 with
// LMUL = 8 and run for any VLEN. strlen, strchr and strcpy read with
// fault-only-first loads, so a string ending at the last byte of a mapped
// page never faults on the over-read.

    .text

// void *memcpy_rvv(void *dst, const void *src, size_t n)
    .globl  memcpy_rvv
    .type   memcpy_rvv, @function
memcpy_rvv:
    mv      a3, a0
1:  vsetvli t0, a2, e8, m8, ta, ma
    vle8.v  v0, (a1)
    add     a1, a1, t0
    sub     a2, a2, t0
    vse8.v  v0, (a3)
    add     a3, a3, t0
    bnez    a2, 1b
    ret
    .size   memcpy_rvv, . - memcpy_rvv

// void *memmove_rvv(void *dst, const void *src, size_t n)
    .globl  memmove_rvv
    .type   memmove_rvv, @function
memmove_rvv:
    sub     t1, a0, a1
    bgeu    t1, a2, memcpy_rvv      // dst - src >= n (unsigned): a forward copy is safe
    add     t2, a0, a2              // overlapping with dst above src: copy backward
    add     t3, a1, a2
1:  vsetvli t0, a2, e8, m8, ta, ma
    sub     t2, t2, t0
    sub     t3, t3, t0
    vle8.v  v0, (t3)
    vse8.v  v0, (t2)
    sub     a2, a2, t0
    bnez    a2, 1b
    ret
    .size   memmove_rvv, . - memmove_rvv

// void *memset_rvv(void *dst, int c, size_t n)
    .globl  memset_rvv
    .type   memset_rvv, @function
memset_rvv:
    mv      a3, a0
1:  vsetvli t0, a2, e8, m8, ta, ma
    vmv.v.x v0, a1
    vse8.v  v0, (a3)
    add     a3, a3, t0
    sub     a2, a2, t0
    bnez    a2, 1b
    ret
    .size   memset_rvv, . - memset_rvv

// int memcmp_rvv(const void *a, const void *b, size_t n)
    .globl  memcmp_rvv
    .type   memcmp_rvv, @function
memcmp_rvv:
    beqz    a2, 3f
1:  vsetvli t0, a2, e8, m8, ta, ma
    vle8.v  v0, (a0)
    vle8.v  v8, (a1)
    vmsne.vv v16, v0, v8
    vfirst.m t1, v16
    bgez    t1, 2f
    add     a0, a0, t0
    add     a1, a1, t0
    sub     a2, a2, t0
    bnez    a2, 1b
3:  li      a0, 0
    ret
2:  add     a0, a0, t1
    add     a1, a1, t1
    lbu     t2, 0(a0)
    lbu     t3, 0(a1)
    sub     a0, t2, t3
    ret
    .size   memcmp_rvv, . - memcmp_rvv

// size_t strlen_rvv(const char *s)
    .globl  strlen_rvv
    .type   strlen_rvv, @function
strlen_rvv:
    mv      a3, a0
1:  vsetvli t0, zero, e8, m8, ta, ma
    vle8ff.v v8, (a3)
    csrr    t1, vl
    vmseq.vi v0, v8, 0
    vfirst.m t2, v0
    bgez    t2, 2f
    add     a3, a3, t1
    j       1b
2:  add     a3, a3, t2
    sub     a0, a3, a0
    ret
    .size   strlen_rvv, . - strlen_rvv

// char *strchr_rvv(const char *s, int c): NULL when the NUL comes first.
    .globl  strchr_rvv
    .type   strchr_rvv, @function
strchr_rvv:
1:  vsetvli t0, zero, e8, m8, ta, ma
    vle8ff.v v8, (a0)
    csrr    t1, vl
    vmseq.vx v16, v8, a1
    vmseq.vi v17, v8, 0
    vmor.mm v18, v16, v17
    vfirst.m t2, v18
    bgez    t2, 2f
    add     a0, a0, t1
    j       1b
2:  add     a0, a0, t2
    lbu     t3, 0(a0)
    andi    t4, a1, 0xff
    beq     t3, t4, 3f
    li      a0, 0
3:  ret
    .size   strchr_rvv, . - strchr_rvv

// char *strcpy_rvv(char *dst, const char *src)
    .globl  strcpy_rvv
    .type   strcpy_rvv, @function
strcpy_rvv:
    mv      a3, a0
1:  vsetvli t0, zero, e8, m8, ta, ma
    vle8ff.v v8, (a1)
    csrr    t1, vl
    vmseq.vi v16, v8, 0
    vfirst.m t2, v16
    bgez    t2, 2f
    vse8.v  v8, (a3)
    add     a1, a1, t1
    add     a3, a3, t1
    j       1b
2:  addi    t2, t2, 1               // copy through the NUL
    vsetvli zero, t2, e8, m8, ta, ma
    vse8.v  v8, (a3)
    ret
    .size   strcpy_rvv, . - strcpy_rvv
