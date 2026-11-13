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

// Floating-point dot products: a0 = a, a1 = b, a2 = n elements. The float32
// and float64 kernels return in fa0; the float16 kernels (Zvfh, Zvfhmin)
// return the binary16 bit pattern or a float32 in fa0 as noted.

    .text

// float32 dot product: vfmul, ordered reduction (bit-exact against a scalar loop without FMA)
    .globl  dot_f32_ord
    .type   dot_f32_ord, @function
dot_f32_ord:
    vsetivli zero, 1, e32, m1, ta, ma
    vmv.s.x v31, zero
1:  beqz    a2, 2f
    vsetvli t0, a2, e32, m1, ta, ma
    vle32.v v0, (a0)
    vle32.v v1, (a1)
    vfmul.vv v2, v0, v1
    vfredosum.vs v31, v2, v31
    slli    t1, t0, 2
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetivli zero, 1, e32, m1, ta, ma
    vfmv.f.s fa0, v31
    ret
    .size   dot_f32_ord, . - dot_f32_ord

// float32 dot product: per-lane vfmacc, tail undisturbed, ordered reduction at the end
    .globl  dot_f32_fma
    .type   dot_f32_fma, @function
dot_f32_fma:
    vsetvli t0, zero, e32, m1, ta, ma
    vmv.v.i v4, 0
1:  beqz    a2, 2f
    vsetvli t0, a2, e32, m1, tu, ma
    vle32.v v0, (a0)
    vle32.v v1, (a1)
    vfmacc.vv v4, v0, v1
    slli    t1, t0, 2
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetvli t0, zero, e32, m1, ta, ma
    vmv.s.x v31, zero
    vfredosum.vs v31, v4, v31
    vfmv.f.s fa0, v31
    ret
    .size   dot_f32_fma, . - dot_f32_fma

// float64 dot product: vfmul, ordered reduction (bit-exact against a scalar loop without FMA)
    .globl  dot_f64_ord
    .type   dot_f64_ord, @function
dot_f64_ord:
    vsetivli zero, 1, e64, m1, ta, ma
    vmv.s.x v31, zero
1:  beqz    a2, 2f
    vsetvli t0, a2, e64, m1, ta, ma
    vle64.v v0, (a0)
    vle64.v v1, (a1)
    vfmul.vv v2, v0, v1
    vfredosum.vs v31, v2, v31
    slli    t1, t0, 3
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetivli zero, 1, e64, m1, ta, ma
    vfmv.f.s fa0, v31
    ret
    .size   dot_f64_ord, . - dot_f64_ord

// float64 dot product: per-lane vfmacc, tail undisturbed, ordered reduction at the end
    .globl  dot_f64_fma
    .type   dot_f64_fma, @function
dot_f64_fma:
    vsetvli t0, zero, e64, m1, ta, ma
    vmv.v.i v4, 0
1:  beqz    a2, 2f
    vsetvli t0, a2, e64, m1, tu, ma
    vle64.v v0, (a0)
    vle64.v v1, (a1)
    vfmacc.vv v4, v0, v1
    slli    t1, t0, 3
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetvli t0, zero, e64, m1, ta, ma
    vmv.s.x v31, zero
    vfredosum.vs v31, v4, v31
    vfmv.f.s fa0, v31
    ret
    .size   dot_f64_fma, . - dot_f64_fma

#ifndef VT_NO_ZVFH
// float16 dot product: per-lane vfmacc, tail undisturbed, ordered reduction at the end
    .globl  dot_f16_fma
    .type   dot_f16_fma, @function
dot_f16_fma:
    vsetvli t0, zero, e16, m1, ta, ma
    vmv.v.i v4, 0
1:  beqz    a2, 2f
    vsetvli t0, a2, e16, m1, tu, ma
    vle16.v v0, (a0)
    vle16.v v1, (a1)
    vfmacc.vv v4, v0, v1
    slli    t1, t0, 1
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetvli t0, zero, e16, m1, ta, ma
    vmv.s.x v31, zero
    vfredosum.vs v31, v4, v31
    vmv.x.s a0, v31
    ret
    .size   dot_f16_fma, . - dot_f16_fma

// float16 dot product with vfwmacc (Zvfh): float16 inputs, float32 lane sums, float32 result
    .globl  dot_f16_fwma
    .type   dot_f16_fwma, @function
dot_f16_fwma:
    vsetvli t0, zero, e32, m1, ta, ma
    vmv.v.i v4, 0
1:  beqz    a2, 2f
    vsetvli t0, a2, e16, mf2, tu, ma
    vle16.v v0, (a0)
    vle16.v v1, (a1)
    vfwmacc.vv v4, v0, v1
    slli    t1, t0, 1
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetvli t0, zero, e32, m1, ta, ma
    vmv.s.x v31, zero
    vfredosum.vs v31, v4, v31
    vfmv.f.s fa0, v31
    ret
    .size   dot_f16_fwma, . - dot_f16_fwma

#endif
// float16 dot product with Zvfhmin only: widen with vfwcvt.f.f.v, float32 vfmacc and ordered reduction; float32 result
    .globl  dot_f16_widen
    .type   dot_f16_widen, @function
dot_f16_widen:
    vsetvli t0, zero, e32, m1, ta, ma
    vmv.v.i v4, 0
1:  beqz    a2, 2f
    vsetvli t0, a2, e16, mf2, ta, ma
    vle16.v v0, (a0)
    vle16.v v1, (a1)
    vfwcvt.f.f.v v2, v0
    vfwcvt.f.f.v v3, v1
    vsetvli zero, t0, e32, m1, tu, ma
    vfmacc.vv v4, v2, v3
    slli    t1, t0, 1
    add     a0, a0, t1
    add     a1, a1, t1
    sub     a2, a2, t0
    j       1b
2:  vsetvli t0, zero, e32, m1, ta, ma
    vmv.s.x v31, zero
    vfredosum.vs v31, v4, v31
    vfmv.f.s fa0, v31
    ret
    .size   dot_f16_widen, . - dot_f16_widen

// float32 to float16 bit pattern with vfncvt.f.f.w (Zvfhmin)
    .globl  f32_to_f16_sum
    .type   f32_to_f16_sum, @function
f32_to_f16_sum:
    vsetivli zero, 1, e32, m1, ta, ma
    vfmv.s.f v8, fa0
    vsetivli zero, 1, e16, mf2, ta, ma
    vfncvt.f.f.w v9, v8
    vmv.x.s a0, v9
    ret
    .size   f32_to_f16_sum, . - f32_to_f16_sum
