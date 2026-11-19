/*
 * Copyright (c) 2026 John Goodacre.
 *
 * This bare-metal floating-point latency and throughput probe prints
 * cycles per operation, in hundredths, for dependent add/subtract, multiply,
 * FMA (through the addend and through the multiplicand), and divide chains,
 * for a square-root/add pair, and for independent add, multiply and FMA
 * streams at both precisions. FP load-to-use measures fld and fmv.x.d
 * per ring node against ld on the same ring. FPLAT_LIMITS checks the
 * dependent add, multiply, FMA and divide figures, the three independent
 * streams, and FP load-to-use.
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
#define RING_NODES 64
static unsigned long ring[RING_NODES * 8] __attribute__((aligned(64)));

#define GROUPS 6

/* Cycles per operation in hundredths: ops per group = 16 bodies x per_body.
 * warm_groups runs before timing to warm instructions and working data. */
static unsigned long
measure(loop_fn fn, const void *arg, unsigned per_body, unsigned long warm_groups, unsigned long id)
{
    fn(warm_groups, arg, 0); /* warm */
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

/* Limits (hundredths): the sync #20 targets (dependent add/multiply/FMA
 * 6-7 cycles, one independent operation per cycle, divide about 15 / 25,
 * FP load-to-use on the early load wakeup) with a small margin. */
#ifndef LIM_DEP
#define LIM_DEP 750
#endif
#ifndef LIM_THR
#define LIM_THR 150
#endif
#ifndef LIM_FDIV_S
#define LIM_FDIV_S 1600
#endif
#ifndef LIM_FDIV_D
#define LIM_FDIV_D 2600
#endif
#ifndef LIM_FLD_NODE
#define LIM_FLD_NODE 950
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
    for (unsigned i = 0; i < RING_NODES; i++)
        ring[i * 8] = (unsigned long) &ring[((i * 37 + 11) % RING_NODES) * 8];

    static const struct test tests[] = {
        {"fadd_dep_s", fadd_dep_s, 2, LIM_DEP},
        {"fadd_dep_d", fadd_dep_d, 2, LIM_DEP},
        {"fmul_dep_s", fmul_dep_s, 2, LIM_DEP},
        {"fmul_dep_d", fmul_dep_d, 2, LIM_DEP},
        {"fmadd_acc_s", fmadd_acc_s, 2, LIM_DEP},
        {"fmadd_acc_d", fmadd_acc_d, 2, LIM_DEP},
        {"fmadd_mul_s", fmadd_mul_s, 2, LIM_DEP},
        {"fmadd_mul_d", fmadd_mul_d, 2, LIM_DEP},
        {"fdiv_dep_s", fdiv_dep_s, 2, LIM_FDIV_S},
        {"fdiv_dep_d", fdiv_dep_d, 2, LIM_FDIV_D},
        {"fsqrt_pair_s", fsqrt_pair_s, 1, 0},
        {"fsqrt_pair_d", fsqrt_pair_d, 1, 0},
        {"fadd_thr_s", fadd_thr_s, 16, LIM_THR},
        {"fadd_thr_d", fadd_thr_d, 16, LIM_THR},
        {"fmul_thr_s", fmul_thr_s, 16, LIM_THR},
        {"fmul_thr_d", fmul_thr_d, 16, LIM_THR},
        {"fmadd_thr_s", fmadd_thr_s, 16, LIM_THR},
        {"fmadd_thr_d", fmadd_thr_d, 16, LIM_THR},
    };
    uart_puts("FPLAT begin\n");
    for (unsigned i = 0; i < sizeof tests / sizeof tests[0]; i++)
        report(tests[i].name,
               measure(tests[i].fn, &konst, tests[i].per_body, 1, 0x7800 + i),
               tests[i].limit);
    /* Warm every ring node so the timed chase measures load-to-use. */
    report("fld_fmv_node", measure(fld_chase, &ring[0], 1, RING_NODES / 16, 0x7880), LIM_FLD_NODE);
    report("ld_node", measure(ld_chase, &ring[0], 2, RING_NODES / 32, 0x7881), 0);
    if (failures) {
        uart_printf("<<FAIL>> %d FP figures over their limits\n", failures);
        return 1;
    }
    uart_puts("FPLAT <<PASS>>\n");
    return 0;
}
