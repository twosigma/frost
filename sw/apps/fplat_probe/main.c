/*
 * Copyright (c) 2026 John Goodacre.
 *
 * FP latency probe, the bare-metal form of the board's fplat test. Prints
 * cycles in hundredths for dependent add/subtract, multiply, fused multiply-add
 * and divide chains, for a square-root/add pair, for independent add, multiply
 * and fused multiply-add streams, and for load-to-use latency. FPLAT_LIMITS
 * bounds multiply and fused multiply-add in both kinds of loop and dependent
 * divide at both precisions.
 */
#include "uart.h"
#include <stdint.h>

typedef unsigned long (*loop_fn)(unsigned long, const void *, unsigned long);

#define DECL(p)                                                                                    \
    extern unsigned long fadd_dep_##p(unsigned long, const void *, unsigned long);                 \
    extern unsigned long fmul_dep_##p(unsigned long, const void *, unsigned long);                 \
    extern unsigned long fmadd_acc_##p(unsigned long, const void *, unsigned long);                \
    extern unsigned long fmadd_mul_##p(unsigned long, const void *, unsigned long);                \
    extern unsigned long fdiv_dep_##p(unsigned long, const void *, unsigned long);                 \
    extern unsigned long fsqrt_pair_##p(unsigned long, const void *, unsigned long);               \
    extern unsigned long fadd_thr_##p(unsigned long, const void *, unsigned long);                 \
    extern unsigned long fmul_thr_##p(unsigned long, const void *, unsigned long);                 \
    extern unsigned long fmadd_thr_##p(unsigned long, const void *, unsigned long);
DECL(s)
DECL(d)
extern unsigned long fld_chase(unsigned long, const void *, unsigned long);
extern unsigned long ld_chase(unsigned long, const void *, unsigned long);

/* Doubles at 0, singles at byte 128; the slots match loops.S. */
static union {
    double d[16];
    float s[64];
} konst;

static void set_const(unsigned k, double v)
{
    konst.d[k] = v;
    konst.s[32 + k] = (float) v;
}

/* 64 ring nodes, 64 bytes apart. */
static unsigned long ring[64 * 8] __attribute__((aligned(64)));

#define GROUPS 6

/* Cycles per operation in hundredths: ops per group = 16 bodies x per_body. */
static unsigned long measure(loop_fn fn, const void *arg, unsigned per_body, unsigned long id)
{
    fn(1, arg, 0); /* warm */
    unsigned long c = fn(GROUPS, arg, id);
    return c * 100 / (GROUPS * 16ul * per_body);
}

static int failures;

static void report(const char *name, unsigned long v, unsigned long limit)
{
    uart_printf("FPLAT %s cycles/op=%lu.%02lu\n", name, v / 100, v % 100);
#ifdef FPLAT_LIMITS
    if (limit && v > limit) {
        uart_printf("FPLAT over limit: %s above %lu.%02lu\n", name, limit / 100, limit % 100);
        failures++;
    }
#else
    (void) limit;
#endif
}

struct test {
    const char *name;
    loop_fn fn;
    unsigned per_body;
    unsigned long limit; /* hundredths of a cycle, 0 for none */
};

/* Limits (hundredths): the sync #19 engine with the DSP multiplier and the
 * radix-4 divider in simulation, plus a margin. */
#ifndef LIM_FMUL
#define LIM_FMUL 1500
#endif
#ifndef LIM_FMA
#define LIM_FMA 2200
#endif
#ifndef LIM_FDIV_S
#define LIM_FDIV_S 3200
#endif
#ifndef LIM_FDIV_D
#define LIM_FDIV_D 4600
#endif

int main(void)
{
    set_const(0, 1.0);
    set_const(1, 1.1);
    set_const(2, 1.0 / 1.1);
    set_const(3, 0.7);
    set_const(4, -0.7);
    set_const(5, 0.5);
    set_const(6, -0.5 / 1.1);
    set_const(7, 0.25);
    set_const(8, 1.5);
    for (unsigned i = 0; i < 64; i++)
        ring[i * 8] = (unsigned long) &ring[((i * 37 + 11) % 64) * 8];

    static const struct test tests[] = {
        {"fadd_dep_s", fadd_dep_s, 2, 0},
        {"fadd_dep_d", fadd_dep_d, 2, 0},
        {"fmul_dep_s", fmul_dep_s, 2, LIM_FMUL},
        {"fmul_dep_d", fmul_dep_d, 2, LIM_FMUL},
        {"fmadd_acc_s", fmadd_acc_s, 2, LIM_FMA},
        {"fmadd_acc_d", fmadd_acc_d, 2, LIM_FMA},
        {"fmadd_mul_s", fmadd_mul_s, 2, LIM_FMA},
        {"fmadd_mul_d", fmadd_mul_d, 2, LIM_FMA},
        {"fdiv_dep_s", fdiv_dep_s, 2, LIM_FDIV_S},
        {"fdiv_dep_d", fdiv_dep_d, 2, LIM_FDIV_D},
        {"fsqrt_pair_s", fsqrt_pair_s, 1, 0},
        {"fsqrt_pair_d", fsqrt_pair_d, 1, 0},
        {"fadd_thr_s", fadd_thr_s, 16, 0},
        {"fadd_thr_d", fadd_thr_d, 16, 0},
        {"fmul_thr_s", fmul_thr_s, 16, LIM_FMUL},
        {"fmul_thr_d", fmul_thr_d, 16, LIM_FMUL},
        {"fmadd_thr_s", fmadd_thr_s, 16, LIM_FMA},
        {"fmadd_thr_d", fmadd_thr_d, 16, LIM_FMA},
    };
    uart_puts("FPLAT begin\n");
    for (unsigned i = 0; i < sizeof tests / sizeof tests[0]; i++)
        report(tests[i].name,
               measure(tests[i].fn, &konst, tests[i].per_body, 0x7800 + i),
               tests[i].limit);
    report("fld_fmv_node", measure(fld_chase, &ring[0], 1, 0x7880), 0);
    report("ld_node", measure(ld_chase, &ring[0], 2, 0x7881), 0);
    if (failures) {
        uart_printf("<<FAIL>> %d FP figures over their limits\n", failures);
        return 1;
    }
    uart_puts("FPLAT <<PASS>>\n");
    return 0;
}
