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
 * DPI-C reference for F/D compute instructions using Spike's Berkeley
 * SoftFloat build (canonical NaN, tininess after rounding). Register values
 * are 64 bits: single-precision operands are unboxed, results are NaN-boxed,
 * and W-form integer results are sign-extended. Non-arithmetic operations
 * follow Spike, including raw FMV bit transfers.
 */

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif
#include "softfloat/softfloat.h"
#ifdef __cplusplus
}
#endif

#ifdef __cplusplus
extern "C" {
#endif

static float32_t f32v(uint32_t v)
{
    float32_t r;
    r.v = v;
    return r;
}

static float64_t f64v(uint64_t v)
{
    float64_t r;
    r.v = v;
    return r;
}

static uint32_t unbox32(uint64_t v)
{
    return ((v >> 32) == 0xFFFFFFFFULL) ? (uint32_t) v : 0x7FC00000U;
}

static uint64_t box32(uint32_t v)
{
    return 0xFFFFFFFF00000000ULL | v;
}

static uint64_t sext32(uint32_t v)
{
    return (uint64_t) (int64_t) (int32_t) v;
}

static bool is_nan32(uint32_t v)
{
    return ((v >> 23) & 0xFFU) == 0xFFU && (v & 0x7FFFFFU) != 0;
}

static bool is_nan64(uint64_t v)
{
    return ((v >> 52) & 0x7FFU) == 0x7FFU && (v & 0xFFFFFFFFFFFFFULL) != 0;
}

#define SIGN32 0x80000000U
#define SIGN64 0x8000000000000000ULL

/* FMIN/FMAX as Spike defines them: -0 orders below +0, a single NaN operand
 * yields the other, two NaNs yield the canonical NaN; the quiet compares raise
 * NV on a signalling NaN. */
static uint32_t minmax32(uint32_t a, uint32_t b, bool is_max)
{
    bool pick_a;
    if (is_max) {
        pick_a =
            f32_lt_quiet(f32v(b), f32v(a)) || (f32_eq(f32v(b), f32v(a)) && ((b & SIGN32) != 0));
    } else {
        pick_a =
            f32_lt_quiet(f32v(a), f32v(b)) || (f32_eq(f32v(a), f32v(b)) && ((a & SIGN32) != 0));
    }
    if (is_nan32(a) && is_nan32(b))
        return 0x7FC00000U;
    return (pick_a || is_nan32(b)) ? a : b;
}

static uint64_t minmax64(uint64_t a, uint64_t b, bool is_max)
{
    bool pick_a;
    if (is_max) {
        pick_a =
            f64_lt_quiet(f64v(b), f64v(a)) || (f64_eq(f64v(b), f64v(a)) && ((b & SIGN64) != 0));
    } else {
        pick_a =
            f64_lt_quiet(f64v(a), f64v(b)) || (f64_eq(f64v(a), f64v(b)) && ((a & SIGN64) != 0));
    }
    if (is_nan64(a) && is_nan64(b))
        return 0x7FF8000000000000ULL;
    return (pick_a || is_nan64(b)) ? a : b;
}

/* DPI-C entry point, imported by fp_engine_equiv_harness.sv. Returns 0 for an
 * operation this model does not know. */
int fp_softfloat_ref(
    const char *op, int rm, uint64_t a, uint64_t b, uint64_t c, uint64_t *result, int *flags);

int fp_softfloat_ref(
    const char *op, int rm, uint64_t a, uint64_t b, uint64_t c, uint64_t *result, int *flags)
{
    uint32_t as = unbox32(a);
    uint32_t bs = unbox32(b);
    uint32_t cs = unbox32(c);
    uint64_t r;

    softfloat_roundingMode = (uint_fast8_t) rm;
    softfloat_detectTininess = softfloat_tininess_afterRounding;
    softfloat_exceptionFlags = 0;

#define OP(name) (strcmp(op, name) == 0)
    if (OP("FADD_S"))
        r = box32(f32_add(f32v(as), f32v(bs)).v);
    else if (OP("FSUB_S"))
        r = box32(f32_sub(f32v(as), f32v(bs)).v);
    else if (OP("FMUL_S"))
        r = box32(f32_mul(f32v(as), f32v(bs)).v);
    else if (OP("FDIV_S"))
        r = box32(f32_div(f32v(as), f32v(bs)).v);
    else if (OP("FSQRT_S"))
        r = box32(f32_sqrt(f32v(as)).v);
    else if (OP("FMADD_S"))
        r = box32(f32_mulAdd(f32v(as), f32v(bs), f32v(cs)).v);
    else if (OP("FMSUB_S"))
        r = box32(f32_mulAdd(f32v(as), f32v(bs), f32v(cs ^ SIGN32)).v);
    else if (OP("FNMSUB_S"))
        r = box32(f32_mulAdd(f32v(as ^ SIGN32), f32v(bs), f32v(cs)).v);
    else if (OP("FNMADD_S"))
        r = box32(f32_mulAdd(f32v(as ^ SIGN32), f32v(bs), f32v(cs ^ SIGN32)).v);
    else if (OP("FSGNJ_S"))
        r = box32((as & ~SIGN32) | (bs & SIGN32));
    else if (OP("FSGNJN_S"))
        r = box32((as & ~SIGN32) | (~bs & SIGN32));
    else if (OP("FSGNJX_S"))
        r = box32(as ^ (bs & SIGN32));
    else if (OP("FMIN_S"))
        r = box32(minmax32(as, bs, false));
    else if (OP("FMAX_S"))
        r = box32(minmax32(as, bs, true));
    else if (OP("FEQ_S"))
        r = f32_eq(f32v(as), f32v(bs));
    else if (OP("FLT_S"))
        r = f32_lt(f32v(as), f32v(bs));
    else if (OP("FLE_S"))
        r = f32_le(f32v(as), f32v(bs));
    else if (OP("FCLASS_S"))
        r = f32_classify(f32v(as));
    else if (OP("FCVT_W_S"))
        r = sext32((uint32_t) f32_to_i32(f32v(as), rm, true));
    else if (OP("FCVT_WU_S"))
        r = sext32((uint32_t) f32_to_ui32(f32v(as), rm, true));
    else if (OP("FCVT_L_S"))
        r = (uint64_t) f32_to_i64(f32v(as), rm, true);
    else if (OP("FCVT_LU_S"))
        r = (uint64_t) f32_to_ui64(f32v(as), rm, true);
    else if (OP("FCVT_S_W"))
        r = box32(i32_to_f32((int32_t) a).v);
    else if (OP("FCVT_S_WU"))
        r = box32(ui32_to_f32((uint32_t) a).v);
    else if (OP("FCVT_S_L"))
        r = box32(i64_to_f32((int64_t) a).v);
    else if (OP("FCVT_S_LU"))
        r = box32(ui64_to_f32(a).v);
    else if (OP("FMV_X_W"))
        r = sext32((uint32_t) a);
    else if (OP("FMV_W_X"))
        r = box32((uint32_t) a);
    else if (OP("FADD_D"))
        r = f64_add(f64v(a), f64v(b)).v;
    else if (OP("FSUB_D"))
        r = f64_sub(f64v(a), f64v(b)).v;
    else if (OP("FMUL_D"))
        r = f64_mul(f64v(a), f64v(b)).v;
    else if (OP("FDIV_D"))
        r = f64_div(f64v(a), f64v(b)).v;
    else if (OP("FSQRT_D"))
        r = f64_sqrt(f64v(a)).v;
    else if (OP("FMADD_D"))
        r = f64_mulAdd(f64v(a), f64v(b), f64v(c)).v;
    else if (OP("FMSUB_D"))
        r = f64_mulAdd(f64v(a), f64v(b), f64v(c ^ SIGN64)).v;
    else if (OP("FNMSUB_D"))
        r = f64_mulAdd(f64v(a ^ SIGN64), f64v(b), f64v(c)).v;
    else if (OP("FNMADD_D"))
        r = f64_mulAdd(f64v(a ^ SIGN64), f64v(b), f64v(c ^ SIGN64)).v;
    else if (OP("FSGNJ_D"))
        r = (a & ~SIGN64) | (b & SIGN64);
    else if (OP("FSGNJN_D"))
        r = (a & ~SIGN64) | (~b & SIGN64);
    else if (OP("FSGNJX_D"))
        r = a ^ (b & SIGN64);
    else if (OP("FMIN_D"))
        r = minmax64(a, b, false);
    else if (OP("FMAX_D"))
        r = minmax64(a, b, true);
    else if (OP("FEQ_D"))
        r = f64_eq(f64v(a), f64v(b));
    else if (OP("FLT_D"))
        r = f64_lt(f64v(a), f64v(b));
    else if (OP("FLE_D"))
        r = f64_le(f64v(a), f64v(b));
    else if (OP("FCLASS_D"))
        r = f64_classify(f64v(a));
    else if (OP("FCVT_W_D"))
        r = sext32((uint32_t) f64_to_i32(f64v(a), rm, true));
    else if (OP("FCVT_WU_D"))
        r = sext32((uint32_t) f64_to_ui32(f64v(a), rm, true));
    else if (OP("FCVT_L_D"))
        r = (uint64_t) f64_to_i64(f64v(a), rm, true);
    else if (OP("FCVT_LU_D"))
        r = (uint64_t) f64_to_ui64(f64v(a), rm, true);
    else if (OP("FCVT_D_W"))
        r = i32_to_f64((int32_t) a).v;
    else if (OP("FCVT_D_WU"))
        r = ui32_to_f64((uint32_t) a).v;
    else if (OP("FCVT_D_L"))
        r = i64_to_f64((int64_t) a).v;
    else if (OP("FCVT_D_LU"))
        r = ui64_to_f64(a).v;
    else if (OP("FCVT_S_D"))
        r = box32(f64_to_f32(f64v(a)).v);
    else if (OP("FCVT_D_S"))
        r = f32_to_f64(f32v(as)).v;
    else if (OP("FMV_X_D") || OP("FMV_D_X"))
        r = a;
    else
        return 0;
#undef OP

    *result = r;
    *flags = (int) (softfloat_exceptionFlags & 0x1FU);
    return 1;
}

#ifdef __cplusplus
}
#endif
