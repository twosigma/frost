/*
 * Copyright (c) 2026 John Goodacre.
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

/**
 * fence.i cost for JIT-style code generation
 *
 * A JIT writes code through the data side, then makes it visible to fetch
 * with fence.i. On the coherent hierarchy fence.i drains the store queue,
 * invalidates the whole L1I and flushes the pipeline; fetch misses obtain
 * dirty L1D bytes through the home's probes. This bench emits straight-line
 * code into cached DDR at run time and times, in cycles:
 *
 *   fence      fence.i alone, with a clean L1D
 *   fence_dirty fence.i after 64 KiB of unrelated L1D stores (no L1D sweep
 *              expected, so this should match fence)
 *   publish    write a two-instruction stub, fence.i, call it
 *   warm/cold  per body size: a call from a warm L1I, then fence.i and the
 *              same call again (the refetch the invalidate-all costs)
 *   first      per body size: the first call after writing the body, whose
 *              lines are still dirty in the L1D
 *
 * Each figure is the minimum and the mean of REPS repetitions. Every call's
 * return value is checked, so stale code fails the run.
 */

#include <stdint.h>

#include "../../lib/include/csr.h"
#include "../../lib/include/uart.h"

#define REPS 8
#define MAX_BODY_INSNS 3072 /* 12 KiB of code, below the 16 KiB L1I */
#define DIRTY_WORDS (64 * 1024 / 4)

#define INSN_ADDI_A0_1 0x00150513u /* addi a0, a0, 1 */
#define INSN_RET 0x00008067u       /* jalr x0, 0(ra) */

__attribute__((section(".ddr_bss"), aligned(64))) static volatile uint32_t ddr_code_buf[MAX_BODY_INSNS + 1];
__attribute__((section(".ddr_bss"), aligned(64))) static volatile uint32_t ddr_stub_buf[8];
__attribute__((section(".ddr_bss"), aligned(64))) static volatile uint32_t ddr_dirty_buf[DIRTY_WORDS];

/* Low-BRAM code cannot reach these with PC-relative addressing, so load their
 * addresses from absolute pointers (as crt0 does for .ddr_bss). */
static volatile uint32_t *volatile const ddr_code_p = ddr_code_buf;
static volatile uint32_t *volatile const ddr_stub_p = ddr_stub_buf;
static volatile uint32_t *volatile const ddr_dirty_p = ddr_dirty_buf;
#define ddr_code (ddr_code_p)
#define ddr_stub (ddr_stub_p)
#define ddr_dirty (ddr_dirty_p)

typedef long (*body_fn_t)(long);

static int failures;

struct stat {
    uint64_t min;
    uint64_t sum;
};

static void stat_init(struct stat *s)
{
    s->min = ~0ull;
    s->sum = 0;
}

static void stat_add(struct stat *s, uint64_t v)
{
    if (v < s->min) {
        s->min = v;
    }
    s->sum += v;
}

static void stat_print(const char *name, unsigned insns, const struct stat *s)
{
    uart_printf("RESULT %s insns=%u min=%llu mean=%llu\n", name, insns,
                (unsigned long long) s->min, (unsigned long long) (s->sum / REPS));
}

static inline void fence_i(void)
{
    __asm__ volatile("fence.i" ::: "memory");
}

static void check(const char *what, unsigned insns, long got, long want)
{
    if (got != want) {
        uart_printf("FAIL: %s insns=%u got %ld want %ld\n", what, insns, got, want);
        failures++;
    }
}

/* Emit insns x "addi a0, a0, 1" and a ret, so f(x) returns x + insns. */
static void emit_body(unsigned insns)
{
    volatile uint32_t *code = ddr_code;
    for (unsigned i = 0; i < insns; i++) {
        code[i] = INSN_ADDI_A0_1;
    }
    code[insns] = INSN_RET;
}

static void bench_fence(void)
{
    struct stat clean, dirty;
    stat_init(&clean);
    stat_init(&dirty);
    for (int r = 0; r < REPS; r++) {
        uint64_t t0 = rdcycle64();
        fence_i();
        uint64_t t1 = rdcycle64();
        stat_add(&clean, t1 - t0);

        volatile uint32_t *dirty_buf = ddr_dirty;
        for (unsigned i = 0; i < DIRTY_WORDS; i += 8) { /* one store per 32-byte line */
            dirty_buf[i] = i + (unsigned) r;
        }
        t0 = rdcycle64();
        fence_i();
        t1 = rdcycle64();
        stat_add(&dirty, t1 - t0);
    }
    stat_print("fence", 0, &clean);
    stat_print("fence_dirty", 0, &dirty);
}

static void bench_publish(void)
{
    struct stat s;
    stat_init(&s);
    volatile uint32_t *stub = ddr_stub;
    body_fn_t fn = (body_fn_t) (uintptr_t) stub;
    for (int r = 0; r < REPS; r++) {
        long imm = 100 + r;
        uint64_t t0 = rdcycle64();
        stub[0] = 0x00000513u | ((uint32_t) imm << 20); /* addi a0, x0, imm */
        stub[1] = INSN_RET;
        fence_i();
        long got = fn(0);
        uint64_t t1 = rdcycle64();
        stat_add(&s, t1 - t0);
        check("publish", 2, got, imm);
    }
    stat_print("publish", 2, &s);
}

static void bench_body(unsigned insns)
{
    struct stat warm, cold, first;
    stat_init(&warm);
    stat_init(&cold);
    stat_init(&first);
    body_fn_t fn = (body_fn_t) (uintptr_t) ddr_code;
    for (int r = 0; r < REPS; r++) {
        emit_body(insns);
        fence_i();
        uint64_t t0 = rdcycle64();
        long got = fn(r);
        uint64_t t1 = rdcycle64();
        stat_add(&first, t1 - t0);
        check("first", insns, got, r + (long) insns);

        (void) fn(0); /* make sure every line is resident */
        t0 = rdcycle64();
        got = fn(r);
        t1 = rdcycle64();
        stat_add(&warm, t1 - t0);
        check("warm", insns, got, r + (long) insns);

        fence_i();
        t0 = rdcycle64();
        got = fn(r);
        t1 = rdcycle64();
        stat_add(&cold, t1 - t0);
        check("cold", insns, got, r + (long) insns);
    }
    stat_print("first", insns, &first);
    stat_print("warm", insns, &warm);
    stat_print("cold", insns, &cold);
}

int main(void)
{
    static const unsigned sizes[] = {256, 1024, 3072}; /* 1, 4 and 12 KiB */

    uart_printf("fencei_bench: REPS=%d\n", REPS);
    bench_fence();
    bench_publish();
    for (unsigned i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
        bench_body(sizes[i]);
    }

    if (failures == 0) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("<<FAIL>> (%d failures)\n", failures);
    }

    while (1) {
    }
    return 0;
}
