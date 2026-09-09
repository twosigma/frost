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

/**
 * DMA coherence torture (Phase 4 slice 1). The DMA test engine
 * (hw/rtl/cpu_and_mem/dma_test_engine.sv) is a second agent reading and
 * writing cached DDR behind the CPU's caches; every check here is a
 * coherence or ordering obligation the cache hierarchy's DMA sequencer and
 * the load queue's coherence port must meet:
 *
 *   copy       the engine reads data the CPU wrote and still holds dirty,
 *              and its writes replace copies the CPU holds (L1D and L0)
 *   corr       a CPU reader of a line the engine keeps rewriting never sees
 *              a value go backwards, including two loads of one address
 *   mp         message passing without an explicit fence: a status load and
 *              a data load in program order with no dependency, so the data
 *              load may execute first; the replay of loads that observed
 *              memory before the DMA write keeps the pair consistent
 *   mp_fence   the same with fence r,r
 *   lrsc       an SC after a DMA write to the reserved line fails; without
 *              the write it succeeds
 *   amo        AMO increments on one dword of a line while the engine keeps
 *              rewriting the other dwords of the same line: no increment is
 *              lost and the engine's bytes stay intact
 *   irq        the completion interrupt arrives after the status word, and
 *              the data is visible from the handler
 *   abort      an aborted transfer quiesces before the buffer is reused
 *   aperture   an out-of-aperture transfer is refused and moves nothing
 *   stress     random CPU stores and engine writes to disjoint dwords of
 *              shared lines, checked against a software model
 *
 * Prints <<PASS>> or <<FAIL>>. Runs in both memory tiers: the buffers live
 * at fixed addresses in cached DDR either way.
 */
#include <stdint.h>

#include "csr.h"
#include "dma_engine.h"
#include "trap.h"
#include "uart.h"

#ifndef MCAUSE_INTERRUPT_BIT
#define MCAUSE_INTERRUPT_BIT (1ul << 63)
#endif
#ifndef INT_MEI
#define INT_MEI 11ul
#endif

#define REG32(a) (*(volatile uint32_t *) (uintptr_t) (a))
#define PLIC_BASE 0x44000000ul
#define PLIC_PRIO(s) REG32(PLIC_BASE + 4ul * (s))
#define PLIC_EN_M REG32(PLIC_BASE + 0x2000ul)
#define PLIC_THR_M REG32(PLIC_BASE + 0x200000ul)
#define PLIC_CLAIM_M REG32(PLIC_BASE + 0x200004ul)

#define LINE_BYTES 32u
#define LINE_WORDS (LINE_BYTES / 4u)

/* Iteration counts: the sim budget is a few hundred thousand cycles; the
 * hardware run scales them up with EXTRA_CFLAGS=-DDMA_TORTURE_SCALE=<n>. */
#ifndef DMA_TORTURE_SCALE
#define DMA_TORTURE_SCALE 1u
#endif
#define CORR_ROUNDS (12u * DMA_TORTURE_SCALE)
#define MP_ROUNDS (24u * DMA_TORTURE_SCALE)
#define AMO_ROUNDS (16u * DMA_TORTURE_SCALE)
#define STRESS_ROUNDS (20u * DMA_TORTURE_SCALE)

/* Buffers in cached DDR at fixed absolute addresses (16 MiB into the
 * region, above every image), line aligned. Absolute pointers, like
 * ddr_test's, because medany code in low BRAM cannot reach DDR symbols with
 * PC-relative addressing; the app initializes every buffer it uses. */
#define BUF_WORDS 256u /* 1 KiB: 32 lines */
#define DDR_SCRATCH 0x81000000u
static volatile uint32_t *const g_src = (volatile uint32_t *) (DDR_SCRATCH + 0x0000u);
static volatile uint32_t *const g_dst = (volatile uint32_t *) (DDR_SCRATCH + 0x1000u);
static volatile uint32_t *const g_line = (volatile uint32_t *) (DDR_SCRATCH + 0x2000u);
static volatile uint32_t *const g_mp = (volatile uint32_t *) (DDR_SCRATCH + 0x2100u);
static volatile uint32_t *const g_amo = (volatile uint32_t *) (DDR_SCRATCH + 0x2200u);
static volatile uint32_t *const g_stress = (volatile uint32_t *) (DDR_SCRATCH + 0x3000u);

static uint32_t g_failures;
volatile uint32_t g_irq_count;
volatile uint32_t g_irq_status;
volatile uint32_t g_irq_data;
volatile uint32_t g_spurious;

static uint32_t pa(volatile void *p)
{
    return (uint32_t) (uintptr_t) p;
}

static void check(const char *name, int ok)
{
    if (ok) {
        uart_printf("%s OK\n", name);
    } else {
        uart_printf("%s FAIL\n", name);
        g_failures++;
    }
}

static uint32_t run_engine(uint32_t src,
                           uint32_t dst,
                           uint32_t len,
                           uint32_t mode,
                           uint32_t pattern,
                           uint32_t status_addr,
                           uint32_t status_value)
{
    dma_engine_setup(src, dst, len, mode, pattern, status_addr, status_value);
    dma_engine_start();
    return dma_engine_wait();
}

static void start_engine(uint32_t src,
                         uint32_t dst,
                         uint32_t len,
                         uint32_t mode,
                         uint32_t pattern,
                         uint32_t status_addr,
                         uint32_t status_value)
{
    dma_engine_setup(src, dst, len, mode, pattern, status_addr, status_value);
    dma_engine_start();
}

/* ---- copy: dirty CPU data into the engine, engine data over CPU copies ---- */
static void test_copy(void)
{
    /* The CPU writes the source (dirty in the L1D) and reads the destination
     * (resident in the L1D and the L0), then the engine copies with a length
     * that leaves partial lines at both ends. */
    for (uint32_t i = 0; i < BUF_WORDS; i++) {
        g_src[i] = 0xA5000000u + i;
        g_dst[i] = 0x5A000000u + i;
    }
    uint32_t sum = 0;
    for (uint32_t i = 0; i < BUF_WORDS; i++)
        sum += g_dst[i];
    const uint32_t off = 12u; /* bytes: starts inside a line */
    const uint32_t len = 25u * LINE_BYTES + 7u;
    uint32_t status =
        run_engine(pa(g_src) + off, pa(g_dst) + off, len, DMA_ENGINE_MODE_COPY, 0, 0, 0);
    int ok = (status & DMA_ENGINE_STATUS_DONE) && !(status & DMA_ENGINE_STATUS_ERROR);
    if (!ok) {
        uart_printf("copy: status=%x lines=%u src=%x dst=%x len=%u mode=%x\n",
                    status,
                    dma_engine_read(DMA_ENGINE_LINES),
                    dma_engine_read(DMA_ENGINE_SRC),
                    dma_engine_read(DMA_ENGINE_DST),
                    dma_engine_read(DMA_ENGINE_LEN),
                    dma_engine_read(DMA_ENGINE_MODE));
    }
    volatile uint8_t *sb = (volatile uint8_t *) g_src;
    volatile uint8_t *db = (volatile uint8_t *) g_dst;
    for (uint32_t b = 0; b < BUF_WORDS * 4u; b++) {
        uint8_t want = (b >= off && b < off + len)
                           ? sb[b]
                           : (uint8_t) ((0x5A000000u + b / 4u) >> (8u * (b % 4u)));
        if (db[b] != want) {
            if (ok)
                uart_printf("copy byte %u: got %02x want %02x\n", b, db[b], want);
            ok = 0;
        }
    }
    check("copy", ok && sum != 0);
    dma_engine_ack();
}

/* ---- corr: values never go backwards, two loads of one address agree ---- */
static void test_corr(void)
{
    g_line[0] = 0;
    uint32_t last = 0;
    int ok = 1;
    for (uint32_t r = 1; r <= CORR_ROUNDS; r++) {
        /* Fill the whole line with r + dword index; dword 0 carries r. */
        start_engine(0, pa(g_line), LINE_BYTES, DMA_ENGINE_MODE_FILL, r, 0, 0);
        for (uint32_t k = 0; k < 64u; k++) {
            uint32_t a = g_line[0];
            uint32_t b = g_line[0];
            if (a < last || b < a || b > r) {
                uart_printf("corr r=%u a=%u b=%u last=%u\n", r, a, b, last);
                ok = 0;
            }
            last = b;
        }
        dma_engine_wait();
        dma_engine_ack();
        if (g_line[0] != r || g_line[7] != r + 7u)
            ok = 0;
        last = r;
    }
    check("corr", ok);
}

/* ---- mp: status after data, read status then data without a dependency ---- */
static void test_mp(int with_fence)
{
    volatile uint32_t *data = &g_mp[0];
    volatile uint32_t *status = &g_mp[LINE_WORDS]; /* the next line */
    *data = 0;
    *status = 0;
    int ok = 1;
    uint32_t violations = 0;
    for (uint32_t r = 1; r <= MP_ROUNDS; r++) {
        /* Engine: fill data's line with r (data = r), then status = r. */
        start_engine(0,
                     pa(data),
                     LINE_BYTES,
                     DMA_ENGINE_MODE_FILL | DMA_ENGINE_MODE_STATUS,
                     r,
                     pa(status),
                     r);
        for (uint32_t k = 0; k < 96u; k++) {
            uint32_t s, d;
            if (with_fence) {
                __asm__ volatile("lw %0, 0(%2)\n"
                                 "fence r, r\n"
                                 "lw %1, 0(%3)\n"
                                 : "=&r"(s), "=&r"(d)
                                 : "r"(status), "r"(data)
                                 : "memory");
            } else {
                __asm__ volatile("lw %0, 0(%2)\n"
                                 "lw %1, 0(%3)\n"
                                 : "=&r"(s), "=&r"(d)
                                 : "r"(status), "r"(data)
                                 : "memory");
            }
            /* Seeing status r implies the data of round r or later. */
            if (d < s)
                violations++;
        }
        dma_engine_wait();
        dma_engine_ack();
        if (*status != r || *data != r)
            ok = 0;
    }
    if (violations) {
        uart_printf("mp%s: %u stale data reads after a fresh status\n",
                    with_fence ? "_fence" : "",
                    violations);
        ok = 0;
    }
    check(with_fence ? "mp_fence" : "mp", ok);
}

/* ---- lrsc ---- */
static uint32_t sc_word(volatile uint32_t *p, uint32_t v)
{
    uint32_t fail;
    __asm__ volatile("sc.w %0, %2, (%1)" : "=&r"(fail) : "r"(p), "r"(v) : "memory");
    return fail;
}
static uint32_t lr_word(volatile uint32_t *p)
{
    uint32_t v;
    __asm__ volatile("lr.w %0, (%1)" : "=&r"(v) : "r"(p) : "memory");
    return v;
}
static void test_lrsc(void)
{
    g_line[0] = 100;
    /* No DMA: LR/SC succeeds. */
    (void) lr_word(&g_line[0]);
    uint32_t fail_plain = sc_word(&g_line[0], 101);
    /* A DMA write to the reserved line between LR and SC: SC must fail. */
    (void) lr_word(&g_line[0]);
    (void) run_engine(0, pa(g_line), LINE_BYTES, DMA_ENGINE_MODE_FILL, 200, 0, 0);
    dma_engine_ack();
    uint32_t fail_dma = sc_word(&g_line[0], 102);
    uint32_t v = g_line[0];
    /* A DMA write to another line leaves the reservation alone. */
    (void) lr_word(&g_line[0]);
    (void) run_engine(0, pa(g_mp), LINE_BYTES, DMA_ENGINE_MODE_FILL, 300, 0, 0);
    dma_engine_ack();
    uint32_t fail_other = sc_word(&g_line[0], 103);
    check("lrsc",
          fail_plain == 0 && fail_dma != 0 && v == 200 && fail_other == 0 && g_line[0] == 103);
}

/* ---- amo: increments on dword 0 while the engine rewrites dwords 2..7 ---- */
static void test_amo(void)
{
    for (uint32_t i = 0; i < LINE_WORDS; i++)
        g_amo[i] = 0;
    int ok = 1;
    uint32_t expected = 0;
    for (uint32_t r = 1; r <= AMO_ROUNDS; r++) {
        /* Engine writes bytes [8, 32) of the line: dword w (2..7) gets
         * r + (w - 2), PATTERN counting from DST's dword. */
        start_engine(0, pa(g_amo) + 8u, LINE_BYTES - 8u, DMA_ENGINE_MODE_FILL, r, 0, 0);
        for (uint32_t k = 0; k < 32u; k++) {
            uint32_t old;
            __asm__ volatile("amoadd.w %0, %2, (%1)"
                             : "=&r"(old)
                             : "r"(&g_amo[0]), "r"(1u)
                             : "memory");
            if (old != expected)
                ok = 0;
            expected++;
        }
        dma_engine_wait();
        dma_engine_ack();
        for (uint32_t w = 2; w < LINE_WORDS; w++) {
            if (g_amo[w] != r + (w - 2u))
                ok = 0;
        }
    }
    check("amo", ok && g_amo[0] == expected);
}

/* ---- irq: the completion interrupt follows the status write ---- */
__attribute__((noinline, used)) void dma_irq_c(void)
{
    uint32_t claim = PLIC_CLAIM_M;
    if (claim == DMA_ENGINE_PLIC_SOURCE) {
        g_irq_status = dma_engine_status();
        g_irq_data = g_mp[0];
        g_irq_count++;
        dma_engine_ack(); /* drops the level */
    } else {
        g_spurious++;
    }
    PLIC_CLAIM_M = claim; /* complete */
}

__attribute__((naked, aligned(4))) static void dma_irq_entry(void)
{
    __asm__ volatile("addi sp, sp, -128\n"
                     "sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n"
                     "sd a0, 32(sp)\n sd a1, 40(sp)\n sd a2, 48(sp)\n sd a3, 56(sp)\n"
                     "sd a4, 64(sp)\n sd a5, 72(sp)\n sd a6, 80(sp)\n sd a7, 88(sp)\n"
                     "sd t3, 96(sp)\n sd t4, 104(sp)\n sd t5, 112(sp)\n sd t6, 120(sp)\n"
                     "csrr t0, mcause\n"
                     "bgez t0, 1f\n"
                     "call dma_irq_c\n"
                     "j 2f\n"
                     "1:\n"
                     "la t0, g_spurious\n lw t1, 0(t0)\n addi t1, t1, 1\n sw t1, 0(t0)\n"
                     "csrr t0, mepc\n addi t0, t0, 4\n csrw mepc, t0\n"
                     "2:\n"
                     "ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n"
                     "ld a0, 32(sp)\n ld a1, 40(sp)\n ld a2, 48(sp)\n ld a3, 56(sp)\n"
                     "ld a4, 64(sp)\n ld a5, 72(sp)\n ld a6, 80(sp)\n ld a7, 88(sp)\n"
                     "ld t3, 96(sp)\n ld t4, 104(sp)\n ld t5, 112(sp)\n ld t6, 120(sp)\n"
                     "addi sp, sp, 128\n"
                     "mret\n");
}

static void test_irq(void)
{
    g_mp[0] = 0;
    g_mp[LINE_WORDS] = 0;
    g_irq_count = 0;
    set_trap_handler(&dma_irq_entry);
    PLIC_PRIO(DMA_ENGINE_PLIC_SOURCE) = 1;
    PLIC_THR_M = 0;
    PLIC_EN_M = 1u << DMA_ENGINE_PLIC_SOURCE;
    enable_external_interrupt();
    enable_interrupts();
    start_engine(0,
                 pa(g_mp),
                 LINE_BYTES,
                 DMA_ENGINE_MODE_FILL | DMA_ENGINE_MODE_STATUS | DMA_ENGINE_MODE_IRQ,
                 0x77u,
                 pa(&g_mp[LINE_WORDS]),
                 0x1234u);
    uint32_t spins = 0;
    while (g_irq_count == 0 && spins < 200000u)
        spins++;
    disable_interrupts();
    disable_external_interrupt();
    PLIC_EN_M = 0;
    int ok = g_irq_count == 1 && (g_irq_status & DMA_ENGINE_STATUS_DONE) &&
             (g_irq_status & DMA_ENGINE_STATUS_IRQ) && g_irq_data == 0x77u &&
             g_mp[LINE_WORDS] == 0x1234u && g_spurious == 0;
    if (!ok) {
        uart_printf("irq: count=%u status=%x data=%x word=%x spurious=%u\n",
                    g_irq_count,
                    g_irq_status,
                    g_irq_data,
                    g_mp[LINE_WORDS],
                    g_spurious);
    }
    check("irq", ok);
}

/* ---- abort: quiesce, then reuse the buffer ---- */
static void test_abort(void)
{
    for (uint32_t i = 0; i < BUF_WORDS; i++)
        g_dst[i] = 0;
    start_engine(0, pa(g_dst), BUF_WORDS * 4u, DMA_ENGINE_MODE_FILL, 0x9000u, 0, 0);
    dma_engine_write(DMA_ENGINE_CTRL, DMA_ENGINE_CTRL_ABORT);
    uint32_t status = dma_engine_wait();
    uint32_t lines = dma_engine_read(DMA_ENGINE_LINES);
    int ok = (status & DMA_ENGINE_STATUS_ERROR) && !(status & DMA_ENGINE_STATUS_DONE) &&
             lines < BUF_WORDS / LINE_WORDS;
    dma_engine_ack();
    /* Every line the engine reported complete carries the pattern; none of
     * the others does. */
    for (uint32_t i = 0; i < BUF_WORDS; i++) {
        uint32_t want = (i < lines * LINE_WORDS) ? 0x9000u + i : 0u;
        if (g_dst[i] != want)
            ok = 0;
    }
    /* Reuse: a full fill lands everywhere. */
    status = run_engine(0, pa(g_dst), BUF_WORDS * 4u, DMA_ENGINE_MODE_FILL, 0xA000u, 0, 0);
    dma_engine_ack();
    if (!(status & DMA_ENGINE_STATUS_DONE))
        ok = 0;
    for (uint32_t i = 0; i < BUF_WORDS; i++) {
        if (g_dst[i] != 0xA000u + i)
            ok = 0;
    }
    check("abort", ok);
}

/* ---- aperture ---- */
/* ---- reprogram: writes while BUSY belong to the next transfer ---- */
static void test_reprogram(void)
{
    /* A long fill with a status word; every register is rewritten while it
     * runs. The running transfer must keep its own destination, pattern,
     * status address and value, and the rewritten registers must describe
     * the next transfer exactly (its length is 0, so it only writes the
     * status word). */
    for (uint32_t i = 0; i < BUF_WORDS; i++)
        g_dst[i] = 0;
    g_line[0] = 0;
    g_line[1] = 0;
    start_engine(0,
                 pa(g_dst),
                 BUF_WORDS * 4u,
                 DMA_ENGINE_MODE_FILL | DMA_ENGINE_MODE_STATUS,
                 0x4000u,
                 pa(&g_line[0]),
                 0x51u);
    dma_engine_setup(
        pa(g_src), pa(g_src), 0, DMA_ENGINE_MODE_STATUS, 0xBADu, pa(&g_line[1]), 0x52u);
    uint32_t status = dma_engine_wait();
    dma_engine_ack();
    int ok = (status & DMA_ENGINE_STATUS_DONE) && !(status & DMA_ENGINE_STATUS_ERROR) &&
             g_line[0] == 0x51u && g_line[1] == 0;
    for (uint32_t i = 0; i < BUF_WORDS; i++) {
        if (g_dst[i] != 0x4000u + i)
            ok = 0;
    }
    /* The rewritten registers run as programmed. */
    dma_engine_start();
    status = dma_engine_wait();
    dma_engine_ack();
    ok = ok && (status & DMA_ENGINE_STATUS_DONE) && g_line[1] == 0x52u && g_line[0] == 0x51u;
    check("reprogram", ok);
}

/* ---- abort_read: an abort in a copy's read phase writes nothing ---- */
static void test_abort_read(void)
{
    for (uint32_t i = 0; i < BUF_WORDS; i++) {
        g_src[i] = 0xC0DE0000u + i;
        g_dst[i] = 0;
    }
    /* The abort lands while the engine's first source read is outstanding
     * (the START write and the ABORT write are back to back), so the read's
     * data must be dropped: no destination line may be written. With the
     * interrupt enabled the abort still raises it, with ERROR set. */
    g_irq_count = 0;
    set_trap_handler(&dma_irq_entry);
    PLIC_PRIO(DMA_ENGINE_PLIC_SOURCE) = 1;
    PLIC_THR_M = 0;
    PLIC_EN_M = 1u << DMA_ENGINE_PLIC_SOURCE;
    enable_external_interrupt();
    enable_interrupts();
    dma_engine_setup(
        pa(g_src), pa(g_dst), BUF_WORDS * 4u, DMA_ENGINE_MODE_COPY | DMA_ENGINE_MODE_IRQ, 0, 0, 0);
    dma_engine_start();
    dma_engine_write(DMA_ENGINE_CTRL, DMA_ENGINE_CTRL_ABORT);
    (void) dma_engine_wait(); /* the handler's ack may already have cleared the flags */
    uint32_t lines = dma_engine_read(DMA_ENGINE_LINES);
    uint32_t spins = 0;
    while (g_irq_count == 0 && spins < 200000u)
        spins++;
    disable_interrupts();
    disable_external_interrupt();
    PLIC_EN_M = 0;
    int ok = lines == 0 && g_irq_count == 1 && (g_irq_status & DMA_ENGINE_STATUS_ERROR) &&
             !(g_irq_status & DMA_ENGINE_STATUS_DONE);
    for (uint32_t i = 0; i < BUF_WORDS; i++) {
        if (g_dst[i] != 0)
            ok = 0;
    }
    if (!ok)
        uart_printf(
            "abort_read: lines=%u irqs=%u irq_status=%x\n", lines, g_irq_count, g_irq_status);
    check("abort_read", ok);
}

static void test_aperture(void)
{
    /* The stack lives in the low BRAM on both memory tiers (link.ld and
     * link_ddr.ld), so a stack word is outside the engine's aperture
     * whichever tier the program runs from; static data moves to DDR on the
     * ddr tier and would be a legal destination there. */
    volatile uint32_t stack_canary = 0xC0FFEE11u;
    uint32_t status = run_engine(0, pa(&stack_canary), 4u, DMA_ENGINE_MODE_FILL, 1, 0, 0);
    int ok = (status & DMA_ENGINE_STATUS_ERROR) && !(status & DMA_ENGINE_STATUS_DONE) &&
             stack_canary == 0xC0FFEE11u;
    dma_engine_ack();
    /* A transfer that runs past the end of the aperture is refused too. */
    status = run_engine(0, 0xBFFFFFE0u, 64u, DMA_ENGINE_MODE_FILL, 1, 0, 0);
    ok = ok && (status & DMA_ENGINE_STATUS_ERROR);
    dma_engine_ack();
    check("aperture", ok);
}

/* ---- stress: disjoint dwords of shared lines, software model ---- */
static uint32_t xorshift(uint32_t *s)
{
    uint32_t x = *s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *s = x;
    return x;
}

static void test_stress(void)
{
    static uint32_t model[BUF_WORDS];
    uint32_t seed = 0x1234567u;
    for (uint32_t i = 0; i < BUF_WORDS; i++) {
        g_stress[i] = 0;
        model[i] = 0;
    }
    int ok = 1;
    for (uint32_t r = 0; r < STRESS_ROUNDS; r++) {
        /* Engine fills dwords [2, 6) of every line in a random range of
         * lines (byte offset 8, length 16 per line, one line at a time). */
        uint32_t line = xorshift(&seed) % (BUF_WORDS / LINE_WORDS);
        uint32_t pattern = xorshift(&seed);
        start_engine(
            0, pa(&g_stress[line * LINE_WORDS]) + 8u, 16u, DMA_ENGINE_MODE_FILL, pattern, 0, 0);
        for (uint32_t w = 2; w < 6; w++)
            model[line * LINE_WORDS + w] = pattern + (w - 2u);
        /* Meanwhile the CPU stores to dwords 0, 1, 6, 7 of random lines and
         * reads random dwords, checking against the model where the engine
         * cannot be mid-write (its dwords of the line being filled are
         * checked after completion). */
        for (uint32_t k = 0; k < 24u; k++) {
            uint32_t l2 = xorshift(&seed) % (BUF_WORDS / LINE_WORDS);
            uint32_t w =
                (xorshift(&seed) & 1u) ? (xorshift(&seed) & 1u) : 6u + (xorshift(&seed) & 1u);
            uint32_t v = xorshift(&seed);
            g_stress[l2 * LINE_WORDS + w] = v;
            model[l2 * LINE_WORDS + w] = v;
            uint32_t rl = xorshift(&seed) % (BUF_WORDS / LINE_WORDS);
            uint32_t rw = xorshift(&seed) % LINE_WORDS;
            if (rl == line && rw >= 2 && rw < 6)
                continue;
            uint32_t got = g_stress[rl * LINE_WORDS + rw];
            if (got != model[rl * LINE_WORDS + rw]) {
                if (ok)
                    uart_printf("stress r=%u line=%u w=%u got=%x want=%x\n",
                                r,
                                rl,
                                rw,
                                got,
                                model[rl * LINE_WORDS + rw]);
                ok = 0;
            }
        }
        dma_engine_wait();
        dma_engine_ack();
    }
    for (uint32_t i = 0; i < BUF_WORDS; i++) {
        if (g_stress[i] != model[i]) {
            if (ok)
                uart_printf("stress final %u got=%x want=%x\n", i, g_stress[i], model[i]);
            ok = 0;
        }
    }
    check("stress", ok);
}

int main(void)
{
    uart_printf("\n=== dma_torture: DMA test engine vs the CPU caches ===\n");
    uart_printf("engine@%x src=%x dst=%x line=%x mp=%x amo=%x stress=%x\n",
                (uint32_t) DMA_ENGINE_BASE,
                pa(g_src),
                pa(g_dst),
                pa(g_line),
                pa(g_mp),
                pa(g_amo),
                pa(g_stress));
    uint32_t idle = dma_engine_status();
    check("idle", idle == 0);
    test_copy();
    test_corr();
    test_mp(0);
    test_mp(1);
    test_lrsc();
    test_amo();
    test_irq();
    test_abort();
    test_abort_read();
    test_reprogram();
    test_aperture();
    test_stress();
    if (g_failures == 0) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("%u failure(s)\n", g_failures);
        uart_printf("<<FAIL>>\n");
    }
    while (1) {
    }
    return 0;
}
