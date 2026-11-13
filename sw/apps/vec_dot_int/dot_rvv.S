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

// Integer dot products at 8, 16, 32 and 64 bits for any VLEN, each strip-mined
// with vsetvli: a0 = a, a1 = b, a2 = n elements, result in a0.
//   dot_i8, dot_u8, dot_su8: widening multiply, widening reduction into 32 bits
//   dot_i16:  widening multiply, widening reduction into 64 bits
//   dot_i32:  widening multiply, reduction at e64
//   dot_i64:  low 64 bits of each product, wrapping sum
//   dot_*_vmacc: multiply-accumulate into per-lane sums with a
//   tail-undisturbed vsetvli, one reduction at the end; wraps modulo 2^SEW

    .text

// int8 x int8 into int32
    .globl  dot_i8
    .type   dot_i8, @function
dot_i8:
    vsetivli zero, 1, e32, m1, ta, ma
    vmv.s.x v31, zero
1:  beqz    a2, 2f
    vsetvli t0, a2, e8, m1, ta, ma
    vle8.v v0, (a0)
    vle8.v v1, (a1)
    vwmul.vv v2, v0, v1
    vsetvli zero, t0, e16, m2, ta, ma
    vwredsum.vs v31, v2, v31
    slli    t1, t0, 0
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetivli zero, 1, e32, m1, ta, ma
    vmv.x.s a0, v31
    ret
    .size   dot_i8, . - dot_i8

// uint8 x uint8 into uint32
    .globl  dot_u8
    .type   dot_u8, @function
dot_u8:
    vsetivli zero, 1, e32, m1, ta, ma
    vmv.s.x v31, zero
1:  beqz    a2, 2f
    vsetvli t0, a2, e8, m1, ta, ma
    vle8.v v0, (a0)
    vle8.v v1, (a1)
    vwmulu.vv v2, v0, v1
    vsetvli zero, t0, e16, m2, ta, ma
    vwredsumu.vs v31, v2, v31
    slli    t1, t0, 0
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetivli zero, 1, e32, m1, ta, ma
    vmv.x.s a0, v31
    ret
    .size   dot_u8, . - dot_u8

// int8 (a) x uint8 (b) into int32
    .globl  dot_su8
    .type   dot_su8, @function
dot_su8:
    vsetivli zero, 1, e32, m1, ta, ma
    vmv.s.x v31, zero
1:  beqz    a2, 2f
    vsetvli t0, a2, e8, m1, ta, ma
    vle8.v v0, (a0)
    vle8.v v1, (a1)
    vwmulsu.vv v2, v0, v1
    vsetvli zero, t0, e16, m2, ta, ma
    vwredsum.vs v31, v2, v31
    slli    t1, t0, 0
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetivli zero, 1, e32, m1, ta, ma
    vmv.x.s a0, v31
    ret
    .size   dot_su8, . - dot_su8

// int16 x int16 into int64
    .globl  dot_i16
    .type   dot_i16, @function
dot_i16:
    vsetivli zero, 1, e64, m1, ta, ma
    vmv.s.x v31, zero
1:  beqz    a2, 2f
    vsetvli t0, a2, e16, m1, ta, ma
    vle16.v v0, (a0)
    vle16.v v1, (a1)
    vwmul.vv v2, v0, v1
    vsetvli zero, t0, e32, m2, ta, ma
    vwredsum.vs v31, v2, v31
    slli    t1, t0, 1
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetivli zero, 1, e64, m1, ta, ma
    vmv.x.s a0, v31
    ret
    .size   dot_i16, . - dot_i16

// int32 dot product into int64: vwmul then vredsum at e64
    .globl  dot_i32
    .type   dot_i32, @function
dot_i32:
    vsetivli zero, 1, e64, m1, ta, ma
    vmv.s.x v31, zero
1:  beqz    a2, 2f
    vsetvli t0, a2, e32, m1, ta, ma
    vle32.v v0, (a0)
    vle32.v v1, (a1)
    vwmul.vv v2, v0, v1
    vsetvli zero, t0, e64, m2, ta, ma
    vredsum.vs v31, v2, v31
    slli    t1, t0, 2
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetivli zero, 1, e64, m1, ta, ma
    vmv.x.s a0, v31
    ret
    .size   dot_i32, . - dot_i32

// int64 dot product, wraps modulo 2^64: vmul then vredsum
    .globl  dot_i64
    .type   dot_i64, @function
dot_i64:
    vsetivli zero, 1, e64, m1, ta, ma
    vmv.s.x v31, zero
1:  beqz    a2, 2f
    vsetvli t0, a2, e64, m1, ta, ma
    vle64.v v0, (a0)
    vle64.v v1, (a1)
    vmul.vv v2, v0, v1
    vredsum.vs v31, v2, v31
    slli    t1, t0, 3
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetivli zero, 1, e64, m1, ta, ma
    vmv.x.s a0, v31
    ret
    .size   dot_i64, . - dot_i64

// int8 dot product, per-lane vmacc, wraps modulo 2^8
    .globl  dot_i8_vmacc
    .type   dot_i8_vmacc, @function
dot_i8_vmacc:
    vsetvli t0, zero, e8, m1, ta, ma
    vmv.v.i v4, 0
1:  beqz    a2, 2f
    vsetvli t0, a2, e8, m1, tu, ma
    vle8.v v0, (a0)
    vle8.v v1, (a1)
    vmacc.vv v4, v0, v1
    slli    t1, t0, 0
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetvli t0, zero, e8, m1, ta, ma
    vmv.s.x v31, zero
    vredsum.vs v31, v4, v31
    vmv.x.s a0, v31
    ret
    .size   dot_i8_vmacc, . - dot_i8_vmacc

// int16 dot product, per-lane vmacc, wraps modulo 2^16
    .globl  dot_i16_vmacc
    .type   dot_i16_vmacc, @function
dot_i16_vmacc:
    vsetvli t0, zero, e16, m1, ta, ma
    vmv.v.i v4, 0
1:  beqz    a2, 2f
    vsetvli t0, a2, e16, m1, tu, ma
    vle16.v v0, (a0)
    vle16.v v1, (a1)
    vmacc.vv v4, v0, v1
    slli    t1, t0, 1
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetvli t0, zero, e16, m1, ta, ma
    vmv.s.x v31, zero
    vredsum.vs v31, v4, v31
    vmv.x.s a0, v31
    ret
    .size   dot_i16_vmacc, . - dot_i16_vmacc

// int32 dot product, per-lane vmacc, wraps modulo 2^32
    .globl  dot_i32_vmacc
    .type   dot_i32_vmacc, @function
dot_i32_vmacc:
    vsetvli t0, zero, e32, m1, ta, ma
    vmv.v.i v4, 0
1:  beqz    a2, 2f
    vsetvli t0, a2, e32, m1, tu, ma
    vle32.v v0, (a0)
    vle32.v v1, (a1)
    vmacc.vv v4, v0, v1
    slli    t1, t0, 2
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetvli t0, zero, e32, m1, ta, ma
    vmv.s.x v31, zero
    vredsum.vs v31, v4, v31
    vmv.x.s a0, v31
    ret
    .size   dot_i32_vmacc, . - dot_i32_vmacc

// int64 dot product, per-lane vmacc, wraps modulo 2^64
    .globl  dot_i64_vmacc
    .type   dot_i64_vmacc, @function
dot_i64_vmacc:
    vsetvli t0, zero, e64, m1, ta, ma
    vmv.v.i v4, 0
1:  beqz    a2, 2f
    vsetvli t0, a2, e64, m1, tu, ma
    vle64.v v0, (a0)
    vle64.v v1, (a1)
    vmacc.vv v4, v0, v1
    slli    t1, t0, 3
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetvli t0, zero, e64, m1, ta, ma
    vmv.s.x v31, zero
    vredsum.vs v31, v4, v31
    vmv.x.s a0, v31
    ret
    .size   dot_i64_vmacc, . - dot_i64_vmacc
