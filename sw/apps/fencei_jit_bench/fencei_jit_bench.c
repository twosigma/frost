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
 * fence.i cost study for JIT-style loops (Milestone 6).
 *
 * One iteration = [write the patched region P] [fence.i] [call the body]. The
 * body is the patched region P (rewritten every iteration) followed by a hot
 * region W that is written once and never changes (the code a JIT does not
 * touch). Each region is either "seq" (straight-line addi, best case for the
 * sequential refetch) or "hop" (one addi and one taken jal per 32-byte line,
 * worst case: every line needs its own fetch round trip).
 *
 * Modes (cycles per iteration, mean and min of ITERS):
 *   wr        write P only (identical bytes), no fence.i, no call
 *   call      call only (warm L1I)                               [floor]
 *   wrcall    write P (identical bytes), call, no fence.i        [legal: bytes unchanged]
 *   wrfcall   write P (identical bytes), fence.i, call           [JIT loop cost]
 *   chgfcall  write P (alternating immediate), fence.i, call     [JIT loop, result checked]
 *   fcall     fence.i, call (nothing written: pure refetch)
 *
 * Also: fence.i alone with an empty L1I, a clean L1D and a full L1I.
 */

#include <stdint.h>

#include "../../lib/include/csr.h"
#include "../../lib/include/uart.h"

#ifndef ITERS
#define ITERS 4
#endif
/* SECTIONS is a bit mask: 1 fence.i alone, 2 sweep seq, 4 sweep hop, 8 mixed seq W, 16 mixed hop W,
 * 32 sweep ilp */
#ifndef SECTIONS
#define SECTIONS 31
#endif
#define MAX_BYTES (24 * 1024)

#define INSN_RET 0x00008067u
#define INSN_NOP 0x00000013u
#define INSN_JAL_PLUS28 0x01c0006fu /* jal x0, +28 */

enum { LAY_SEQ = 0, LAY_HOP = 1, LAY_ILP = 2 };
static const char *const lay_name[3] = {"seq", "hop", "ilp"};
enum { M_WR, M_CALL, M_WRCALL, M_WRFCALL, M_CHGFCALL, M_FCALL, M_COUNT };
static const char *const mode_name[M_COUNT] = {
    "wr", "call", "wrcall", "wrfcall", "chgfcall", "fcall"};

__attribute__((section(".ddr_bss"),
               aligned(4096))) static volatile uint32_t ddr_code_buf[MAX_BYTES / 4];
static volatile uint32_t *volatile const ddr_code_p = ddr_code_buf;
#define ddr_code (ddr_code_p)

typedef long (*body_fn_t)(long);
static int failures;

static inline void fence_i(void)
{
    __asm__ volatile("fence.i" ::: "memory");
}

static inline uint32_t addi_a0(uint32_t imm)
{
    return 0x00050513u | (imm << 20);
}

/* Emit a region of `bytes` at word offset `off`. Returns the number of addi
 * instructions that execute in it. The last region ends in a ret. */
static unsigned emit_region(unsigned off, unsigned bytes, int lay, uint32_t imm, int last)
{
    volatile uint32_t *c = ddr_code + off;
    unsigned words = bytes / 4;
    unsigned n = 0;
    if (lay == LAY_ILP) {
        /* four independent addi chains (a0..a3): the core can issue them in parallel */
        for (unsigned i = 0; i < words; i++) {
            uint32_t r = 10 + (i & 3);
            c[i] = 0x00000013u | (r << 7) | (r << 15) | (imm << 20);
        }
        n = words / 4;
        if (last) {
            c[words - 1] = INSN_RET;
        }
    } else if (lay == LAY_SEQ) {
        for (unsigned i = 0; i < words; i++) {
            c[i] = addi_a0(imm);
        }
        n = words;
        if (last) {
            c[words - 1] = INSN_RET;
            n--;
        }
    } else {
        unsigned lines = bytes / 32;
        for (unsigned l = 0; l < lines; l++) {
            c[l * 8 + 0] = addi_a0(imm);
            c[l * 8 + 1] = INSN_JAL_PLUS28;
            for (unsigned k = 2; k < 8; k++) {
                c[l * 8 + k] = INSN_NOP;
            }
            n++;
        }
        if (last) {
            c[(lines - 1) * 8 + 1] = INSN_RET;
        }
    }
    return n;
}

static unsigned count_addi(unsigned bytes, int lay, int last)
{
    if (lay == LAY_ILP) {
        return bytes / 16;
    }
    if (lay == LAY_SEQ) {
        return bytes / 4 - (last ? 1u : 0u);
    }
    return bytes / 32;
}

static void
report(const char *mode, unsigned p, int pl, unsigned w, int wl, uint64_t sum, uint64_t mn)
{
    uart_printf("RESULT %s P=%u/%s W=%u/%s mean=%llu min=%llu\n",
                mode,
                p,
                lay_name[pl],
                w,
                lay_name[wl],
                (unsigned long long) (sum / ITERS),
                (unsigned long long) mn);
}

static void run_mode(int mode, unsigned p, int pl, unsigned w, int wl)
{
    unsigned total = p + w;
    unsigned wlast = (w != 0);
    body_fn_t fn = (body_fn_t) (uintptr_t) ddr_code;
    /* hop regions need 32-byte multiples */
    unsigned n_w = w ? count_addi(w, wl, 1) : 0;
    unsigned n_p_same = count_addi(p, pl, !wlast);

    /* Build the identical-bytes baseline image and make it visible. */
    unsigned n_p = emit_region(0, p, pl, 1, !wlast);
    if (w) {
        (void) emit_region(p / 4, w, wl, 1, 1);
    }
    (void) n_p;
    fence_i();
    (void) fn(0); /* warm the L1I with the full body */
    (void) fn(0);

    uint64_t sum = 0, mn = ~0ull;
    for (int it = -1; it < ITERS; it++) {
        uint32_t imm = 1;
        if (mode == M_CHGFCALL) {
            imm = 1 + (uint32_t) (it & 1); /* 1 or 2 */
        }
        uint64_t t0 = rdcycle64();
        if (mode == M_WR || mode == M_WRCALL || mode == M_WRFCALL || mode == M_CHGFCALL) {
            (void) emit_region(0, p, pl, imm, !wlast);
        }
        if (mode == M_WRFCALL || mode == M_CHGFCALL || mode == M_FCALL) {
            fence_i();
        }
        long got = 0;
        if (mode != M_WR) {
            got = fn(it);
        }
        uint64_t t1 = rdcycle64();
        if (mode != M_WR) {
            long want = it + (long) n_p_same * imm + (long) n_w;
            if (got != want) {
                uart_printf(
                    "FAIL: %s P=%u W=%u got %ld want %ld\n", mode_name[mode], p, w, got, want);
                failures++;
            }
        }
        if (it >= 0) {
            uint64_t d = t1 - t0;
            sum += d;
            if (d < mn) {
                mn = d;
            }
        }
    }
    report(mode_name[mode], p, pl, w, wl, sum, mn);
    (void) total;
}

static void bench_fence_alone(void)
{
    uint64_t t0, t1;
    body_fn_t fn = (body_fn_t) (uintptr_t) ddr_code;
    static const unsigned sizes[] = {4096, 16384};

    fence_i();
    fence_i();
    t0 = rdcycle64();
    fence_i();
    t1 = rdcycle64();
    uart_printf("RESULT fence_empty_l1i cycles=%llu\n", (unsigned long long) (t1 - t0));
    t0 = rdcycle64();
    t1 = rdcycle64();
    uart_printf("RESULT rdcycle_overhead cycles=%llu\n", (unsigned long long) (t1 - t0));

    for (unsigned s = 0; s < 2; s++) {
        (void) emit_region(0, sizes[s], LAY_SEQ, 1, 1);
        fence_i();
        (void) fn(0); /* fill the L1I with sizes[s] bytes of code */
        (void) fn(0);
        t0 = rdcycle64();
        fence_i();
        t1 = rdcycle64();
        uart_printf(
            "RESULT fence_l1i_filled_%u cycles=%llu\n", sizes[s], (unsigned long long) (t1 - t0));
        (void) fn(0); /* refill, fence again with a second fence right after */
        fence_i();
        t0 = rdcycle64();
        fence_i();
        t1 = rdcycle64();
        uart_printf(
            "RESULT fence_second_%u cycles=%llu\n", sizes[s], (unsigned long long) (t1 - t0));
    }
}

int main(void)
{
    static const unsigned n_sweep[] = {64, 256, 1024, 4096, 8192, 16384};
    static const unsigned w_sizes[] = {4096, 12288};
    static const unsigned p_sizes[] = {32, 256, 1024};

    uart_printf("fencei_jit_bench: ITERS=%d SECTIONS=%d\n", ITERS, SECTIONS);
    if (SECTIONS & 1) {
        bench_fence_alone();
    }

    /* (b) N sweep, whole body patched each iteration (W = 0) */
    for (int lay = 0; lay < 3; lay++) {
        if (!(SECTIONS & (lay == 0 ? 2 : (lay == 1 ? 4 : 32)))) {
            continue;
        }
        for (unsigned i = 0; i < sizeof(n_sweep) / sizeof(n_sweep[0]); i++) {
            for (int m = 0; m < M_COUNT; m++) {
                run_mode(m, n_sweep[i], lay, 0, LAY_SEQ);
            }
        }
    }

    /* (c) small patch P inside a hot unmodified region W */
    for (int wl = 0; wl < 2; wl++) {
        if (!(SECTIONS & (wl ? 16 : 8))) {
            continue;
        }
        for (unsigned wi = 0; wi < sizeof(w_sizes) / sizeof(w_sizes[0]); wi++) {
            for (unsigned pi = 0; pi < sizeof(p_sizes) / sizeof(p_sizes[0]); pi++) {
                run_mode(M_CALL, p_sizes[pi], LAY_SEQ, w_sizes[wi], wl);
                run_mode(M_WRCALL, p_sizes[pi], LAY_SEQ, w_sizes[wi], wl);
                run_mode(M_WRFCALL, p_sizes[pi], LAY_SEQ, w_sizes[wi], wl);
                run_mode(M_FCALL, p_sizes[pi], LAY_SEQ, w_sizes[wi], wl);
            }
        }
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
