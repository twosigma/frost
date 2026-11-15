/*
 *    Copyright (c) 2026 John Goodacre
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
 * Full-line stores end to end: the store queue's hints and overlapped cached
 * writes into the L1D's gather, pair and claim logic, checked against a model.
 *
 * streams   memset- and memcpy-like streams with irregular gaps between the
 *           stores, unaligned starts and partial last lines, over cold and
 *           warm lines; every byte inside and around each stream is checked
 *           through loads, then again after cbo.flush.
 * squash    stores of a line being gathered, followed by stores on a
 *           mispredicted branch path, and by a faulting load whose younger
 *           stores the flush removes and the trap's return re-executes.
 * order     two cached plain stores, then at once a younger load of the same
 *           dword (forwarding), fence, fence.i, cbo.clean, cbo.flush,
 *           cbo.inval, cbo.zero, or LR/SC to the same line.
 * dma       the DMA engine reads and writes lines that the CPU writes whole,
 *           so its snoops reach blocks between their acquisition without a
 *           fill and their second sector's install; the DMA's copies and the
 *           final memory are checked per dword, then a quiet copy must match
 *           the CPU's view exactly.
 *
 * The cocotb watch (cocotb_tests/cache/full_line_watch.py) requires the
 * store-queue and L1D events that each part exists to reach.
 */
#include <stdint.h>

#include "csr.h"
#include "dma_engine.h"
#include "uart.h"

#define REGION 0x81200000ul
#define STREAM_BASE (REGION + 0x00000ul)
#define STREAM_SPAN 0x40000ul /* 256 KiB, twice the L1D */
#define SRC_BASE (REGION + 0x80000ul)
#define SQUASH_BASE (REGION + 0xC0000ul)
#define ORDER_BASE (REGION + 0xD0000ul)
#define DMA_LINES 32u
#define DMA_BYTES (DMA_LINES * 64u)
#define DMA_R (REGION + 0x100000ul)
#define DMA_B (REGION + 0x110000ul)
/* Bits above the physical address width: a load access fault. */
#define FAULT_ADDR 0x0000010000001000ul

#define CBO_INVAL(p) __asm__ volatile(".insn i 0x0F, 2, x0, %0, 0" ::"r"(p) : "memory")
#define CBO_CLEAN(p) __asm__ volatile(".insn i 0x0F, 2, x0, %0, 1" ::"r"(p) : "memory")
#define CBO_FLUSH(p) __asm__ volatile(".insn i 0x0F, 2, x0, %0, 2" ::"r"(p) : "memory")
#define CBO_ZERO(p) __asm__ volatile(".insn i 0x0F, 2, x0, %0, 4" ::"r"(p) : "memory")

volatile uint64_t traps;
static uint32_t g_failures;
static uint64_t g_rng;

__attribute__((naked, aligned(4))) static void skip_trap(void)
{
    __asm__ volatile("addi sp, sp, -16\n"
                     "sd t0, 0(sp)\n"
                     "sd t1, 8(sp)\n"
                     "la t0, traps\n"
                     "ld t1, 0(t0)\n"
                     "addi t1, t1, 1\n"
                     "sd t1, 0(t0)\n"
                     "csrr t0, mepc\n"
                     "addi t0, t0, 4\n"
                     "csrw mepc, t0\n"
                     "ld t0, 0(sp)\n"
                     "ld t1, 8(sp)\n"
                     "addi sp, sp, 16\n"
                     "mret\n");
}

static uint64_t rnd(void)
{
    g_rng ^= g_rng << 13;
    g_rng ^= g_rng >> 7;
    g_rng ^= g_rng << 17;
    return g_rng;
}

static uint64_t mix(uint64_t seed, uint64_t addr)
{
    uint64_t z = seed * 0x9E3779B97F4A7C15ull ^ (addr >> 3) * 0xBF58476D1CE4E5B9ull;
    z ^= z >> 31;
    return z | 1u;
}

static uint8_t model_byte(uint64_t seed, uint64_t addr)
{
    return (uint8_t) (mix(seed, addr & ~7ul) >> (8 * (addr & 7)));
}

static void fail(const char *what, uint64_t addr, uint64_t got, uint64_t want)
{
    if (g_failures < 16)
        uart_printf("FAIL %s %lx got=%lx want=%lx\n", what, addr, got, want);
    g_failures++;
}

/* A gap of zero to about a dozen cycles; occasionally a divide's worth. */
static void gap(void)
{
    uint64_t r = rnd();
    uint32_t n = (uint32_t) (r & 7) < 5 ? (uint32_t) (r >> 8) % 3 : (uint32_t) (r >> 8) % 12;
    for (uint32_t i = 0; i < n; i++)
        __asm__ volatile("nop");
    if ((r >> 20) % 16 == 0) {
        uint64_t q = r | 1, d = 3;
        __asm__ volatile("div %0, %0, %1" : "+r"(q) : "r"(d));
        __asm__ volatile("" ::"r"(q));
    }
}

/* Fill [addr, addr + len) with the model's bytes for seed at addr + shift, as
 * memset and copy loops do: bytes to a dword boundary, dwords, tail bytes. A
 * copy's source takes the bytes of its destination (shift = dst - src, a
 * multiple of eight). */
static void fill_model(uint64_t addr, uint64_t len, uint64_t seed, uint64_t shift, int gaps)
{
    uint64_t end = addr + len;
    while (addr < end && (addr & 7)) {
        *(volatile uint8_t *) addr = model_byte(seed, addr + shift);
        addr++;
        if (gaps)
            gap();
    }
    while (addr + 8 <= end) {
        *(volatile uint64_t *) addr = mix(seed, addr + shift);
        addr += 8;
        if (gaps)
            gap();
    }
    while (addr < end) {
        *(volatile uint8_t *) addr = model_byte(seed, addr + shift);
        addr++;
        if (gaps)
            gap();
    }
}

static void fill_gapped(uint64_t addr, uint64_t len, uint64_t seed, int gaps)
{
    fill_model(addr, len, seed, 0, gaps);
}

/* Copy as copy_from_user does when both offsets match: loads and stores. */
static void copy_gapped(uint64_t dst, uint64_t src, uint64_t len)
{
    uint64_t end = dst + len;
    while (dst < end && (dst & 7)) {
        *(volatile uint8_t *) dst++ = *(volatile uint8_t *) src++;
        gap();
    }
    while (dst + 8 <= end) {
        *(volatile uint64_t *) dst = *(volatile uint64_t *) src;
        dst += 8;
        src += 8;
        gap();
    }
    while (dst < end) {
        *(volatile uint8_t *) dst++ = *(volatile uint8_t *) src++;
        gap();
    }
}

static void check_range(const char *what, uint64_t addr, uint64_t len, uint64_t seed)
{
    for (uint64_t a = addr; a < addr + len; a++) {
        uint8_t got = *(volatile uint8_t *) a;
        uint8_t want = model_byte(seed, a);
        if (got != want)
            fail(what, a, got, want);
    }
}

static void flush_range(uint64_t addr, uint64_t len)
{
    for (uint64_t a = addr & ~63ul; a < addr + len; a += 64)
        CBO_FLUSH(a);
    __asm__ volatile("fence rw, rw" ::: "memory");
}

static void test_streams(void)
{
    for (uint32_t round = 0; round < 48; round++) {
        uint64_t r = rnd();
        uint64_t start = STREAM_BASE + 128 + ((r % (STREAM_SPAN - 4096)) & ~(r & 64 ? 0ul : 7ul));
        uint64_t len = 1 + (r >> 24) % 700;
        uint64_t seed = 0x1000 + round, guard = 0x2000 + round;
        /* Background around the stream, then out of the L1D on odd rounds. */
        fill_gapped(start - 64, len + 128, guard, 0);
        if (round & 1)
            flush_range(start - 64, len + 128);
        if (round % 3 == 2) {
            uint64_t src = SRC_BASE + (start & 0xFFF);
            fill_model(src, len, seed, start - src, 0);
            copy_gapped(start, src, len);
        } else {
            fill_gapped(start, len, seed, 1);
        }
        check_range("stream", start, len, seed);
        check_range("below", start - 64, 64, guard);
        check_range("above", start + len, 64, guard);
        flush_range(start - 64, len + 128);
        check_range("stream_mem", start, len, seed);
        check_range("above_mem", start + len, 64, guard);
    }
}

static void check_line(const char *what, volatile uint64_t *p, const uint64_t *want)
{
    for (int i = 0; i < 8; i++)
        if (p[i] != want[i])
            fail(what, (uint64_t) (uintptr_t) &p[i], p[i], want[i]);
}

static void test_squash(void)
{
    uint64_t traps_before = traps;
    for (uint32_t i = 0; i < 64; i++) {
        volatile uint64_t *p = (volatile uint64_t *) (SQUASH_BASE + 64ul * i);
        uint64_t v = mix(0x3000, i), w = ~v, x = rnd() >> 3, one = 1;
        uint64_t want[8];
        for (int k = 0; k < 8; k++)
            want[k] = v;
        if (x & 1)
            want[2] = w;
        /* The branch waits for a divide, so its prediction runs ahead with
         * stores of the gathered line on either path. */
        __asm__ volatile(".option push\n.option norvc\n"
                         "div t0, %[x], %[one]\n"
                         "andi t0, t0, 1\n"
                         "sd %[v], 0(%[p])\n"
                         "sd %[v], 8(%[p])\n"
                         "beqz t0, 1f\n"
                         "sd %[w], 16(%[p])\n"
                         "j 2f\n"
                         "1: sd %[v], 16(%[p])\n"
                         "2: sd %[v], 24(%[p])\n"
                         "sd %[v], 32(%[p])\n"
                         "sd %[v], 40(%[p])\n"
                         "sd %[v], 48(%[p])\n"
                         "sd %[v], 56(%[p])\n"
                         ".option pop\n"
                         :
                         : [x] "r"(x), [one] "r"(one), [p] "r"(p), [v] "r"(v), [w] "r"(w)
                         : "t0", "memory");
        check_line("mispredict", p, want);
    }
    for (uint32_t i = 0; i < 32; i++) {
        volatile uint64_t *p = (volatile uint64_t *) (SQUASH_BASE + 0x2000ul + 64ul * i);
        uint64_t v = mix(0x3100, i);
        uint64_t want[8];
        for (int k = 0; k < 8; k++)
            want[k] = v;
        uint64_t bad = FAULT_ADDR;
        /* The faulting load sits inside the line's stores, after zero to
         * fifteen loop turns, so the flush meets the gather window at several
         * ages; the stores after it are flushed, then run again after the
         * trap returns. */
        uint64_t turns = i % 16;
        __asm__ volatile(".option push\n.option norvc\n"
                         "sd %[v], 0(%[p])\n"
                         "sd %[v], 8(%[p])\n"
                         "sd %[v], 16(%[p])\n"
                         "3: beqz %[d], 4f\n"
                         "addi %[d], %[d], -1\n"
                         "j 3b\n"
                         "4: ld t1, 0(%[bad])\n"
                         "sd %[v], 24(%[p])\n"
                         "sd %[v], 32(%[p])\n"
                         "sd %[v], 40(%[p])\n"
                         "sd %[v], 48(%[p])\n"
                         "sd %[v], 56(%[p])\n"
                         ".option pop\n"
                         : [d] "+r"(turns)
                         : [p] "r"(p), [v] "r"(v), [bad] "r"(bad)
                         : "t1", "memory");
        check_line("fault", p, want);
        flush_range((uint64_t) (uintptr_t) p, 64);
        check_line("fault_mem", p, want);
    }
    if (traps - traps_before != 32)
        fail("fault_traps", 0, traps - traps_before, 32);
}

static void test_order(void)
{
    for (uint32_t i = 0; i < 24; i++) {
        uint64_t base = ORDER_BASE + 0x400ul * i;
        volatile uint64_t *p = (volatile uint64_t *) base;
        uint64_t a = mix(0x4000, i), b = mix(0x4100, i), c = mix(0x4200, i);
        uint64_t old[8], r, s, o;
        for (int k = 0; k < 8; k++)
            old[k] = p[k] = mix(0x4300 + i, k);
        if (i & 1)
            flush_range(base, 64);
        else
            __asm__ volatile("ld %0, 0(%1)" : "=r"(r) : "r"(p) : "memory");
        switch (i % 8) {
            case 0: /* same-dword forwarding from the younger of two stores */
                __asm__ volatile("sd %[a], 0(%[p])\nsd %[b], 0(%[p])\nld %[r], 0(%[p])\n"
                                 : [r] "=&r"(r)
                                 : [p] "r"(p), [a] "r"(a), [b] "r"(b)
                                 : "memory");
                if (r != b)
                    fail("forward", base, r, b);
                old[0] = b;
                break;
            case 1: /* two sectors, then a fence */
                __asm__ volatile(
                    "sd %[a], 8(%[p])\nsd %[b], 40(%[p])\nfence rw, rw\nld %[r], 40(%[p])\n"
                    : [r] "=&r"(r)
                    : [p] "r"(p), [a] "r"(a), [b] "r"(b)
                    : "memory");
                if (r != b)
                    fail("fence", base, r, b);
                old[1] = a;
                old[5] = b;
                break;
            case 2:
                __asm__ volatile("sd %[a], 0(%[p])\nsd %[b], 32(%[p])\nfence.i\nld %[r], 0(%[p])\n"
                                 : [r] "=&r"(r)
                                 : [p] "r"(p), [a] "r"(a), [b] "r"(b)
                                 : "memory");
                if (r != a)
                    fail("fence_i", base, r, a);
                old[0] = a;
                old[4] = b;
                break;
            case 3:
                __asm__ volatile("sd %[a], 16(%[p])\nsd %[b], 48(%[p])\n"
                                 ".insn i 0x0F, 2, x0, %[p], 1\nld %[r], 16(%[p])\n"
                                 : [r] "=&r"(r)
                                 : [p] "r"(p), [a] "r"(a), [b] "r"(b)
                                 : "memory");
                if (r != a)
                    fail("clean", base, r, a);
                old[2] = a;
                old[6] = b;
                break;
            case 4:
                __asm__ volatile("sd %[a], 0(%[p])\nsd %[b], 56(%[p])\n"
                                 ".insn i 0x0F, 2, x0, %[p], 2\nld %[r], 56(%[p])\n"
                                 : [r] "=&r"(r)
                                 : [p] "r"(p), [a] "r"(a), [b] "r"(b)
                                 : "memory");
                if (r != b)
                    fail("flush", base, r, b);
                old[0] = a;
                old[7] = b;
                break;
            case 5: { /* cbo.inval may keep or discard the stores, dword by dword */
                uint64_t mem[8];
                flush_range(base, 64);
                for (int k = 0; k < 8; k++)
                    mem[k] = p[k];
                __asm__ volatile("sd %[a], 0(%[p])\nsd %[b], 32(%[p])\n"
                                 ".insn i 0x0F, 2, x0, %[p], 0\n"
                                 :
                                 : [p] "r"(p), [a] "r"(a), [b] "r"(b)
                                 : "memory");
                uint64_t g0 = p[0], g4 = p[4];
                if (g0 != a && g0 != mem[0])
                    fail("inval0", base, g0, a);
                if (g4 != b && g4 != mem[4])
                    fail("inval4", base, g4, b);
                old[0] = g0;
                old[4] = g4;
                break;
            }
            case 6:
                __asm__ volatile("sd %[a], 0(%[p])\nsd %[b], 40(%[p])\n"
                                 ".insn i 0x0F, 2, x0, %[p], 4\n"
                                 "sd %[c], 8(%[p])\nld %[r], 40(%[p])\n"
                                 : [r] "=&r"(r)
                                 : [p] "r"(p), [a] "r"(a), [b] "r"(b), [c] "r"(c)
                                 : "memory");
                if (r != 0)
                    fail("zero", base, r, 0);
                for (int k = 0; k < 8; k++)
                    old[k] = 0;
                old[1] = c;
                break;
            default:
                __asm__ volatile("sd %[a], 0(%[p])\nsd %[b], 32(%[p])\n"
                                 "addi t0, %[p], 16\n"
                                 "lr.d %[o], (t0)\nsc.d %[s], %[c], (t0)\n"
                                 : [o] "=&r"(o), [s] "=&r"(s)
                                 : [p] "r"(p), [a] "r"(a), [b] "r"(b), [c] "r"(c)
                                 : "t0", "memory");
                if (o != old[2])
                    fail("lr", base, o, old[2]);
                old[0] = a;
                old[4] = b;
                if (s == 0)
                    old[2] = c;
                break;
        }
        check_line("order", p, old);
        flush_range(base, 64);
        check_line("order_mem", p, old);
    }
}

static uint64_t tagged(uint32_t line, uint32_t dw, uint32_t version)
{
    return ((uint64_t) version << 32) | (line << 8) | dw;
}

static void write_lines(uint32_t first, uint32_t version, int gaps)
{
    for (uint32_t n = 0; n < DMA_LINES; n++) {
        uint32_t line = (first + n) % DMA_LINES;
        volatile uint64_t *p = (volatile uint64_t *) (DMA_R + 64ul * line);
        for (uint32_t dw = 0; dw < 8; dw++) {
            p[dw] = tagged(line, dw, version);
            if (gaps)
                gap();
        }
    }
}

static void flush_dma_region(void)
{
    flush_range(DMA_R, DMA_BYTES);
    flush_range(DMA_B, DMA_BYTES);
}

static uint32_t dma_run(uint64_t src, uint64_t dst, uint32_t mode, uint32_t pattern)
{
    dma_engine_setup((uint32_t) src,
                     (uint32_t) dst,
                     DMA_BYTES / (mode & DMA_ENGINE_MODE_FILL ? 2 : 1),
                     mode,
                     pattern,
                     0,
                     0);
    dma_engine_start();
    return 0;
}

static void test_dma(void)
{
    uint32_t version = 1;
    write_lines(0, version, 0);
    for (uint32_t round = 0; round < 12; round++) {
        uint32_t burst = round & 1 ? DMA_ENGINE_MODE_BURST : 0;
        uint32_t first = (uint32_t) rnd() % DMA_LINES;
        /* DMA copies R while the CPU writes every line of R whole. */
        flush_dma_region();
        uint32_t lo = version;
        version++;
        dma_run(DMA_R, DMA_B, DMA_ENGINE_MODE_COPY | burst, 0);
        write_lines(first, version, round & 2);
        if (dma_engine_wait() & DMA_ENGINE_STATUS_ERROR)
            fail("dma_copy_error", round, 0, 0);
        for (uint32_t line = 0; line < DMA_LINES; line++)
            for (uint32_t dw = 0; dw < 8; dw++) {
                uint64_t got = *(volatile uint64_t *) (DMA_B + 64ul * line + 8ul * dw);
                uint32_t v = (uint32_t) (got >> 32);
                if ((uint32_t) got != ((line << 8) | dw) || v < lo || v > version)
                    fail(
                        "dma_read", DMA_B + 64ul * line + 8ul * dw, got, tagged(line, dw, version));
            }
        for (uint32_t line = 0; line < DMA_LINES; line++)
            for (uint32_t dw = 0; dw < 8; dw++) {
                uint64_t got = *(volatile uint64_t *) (DMA_R + 64ul * line + 8ul * dw);
                if (got != tagged(line, dw, version))
                    fail("cpu_after_copy", DMA_R + 64ul * line, got, tagged(line, dw, version));
            }
        /* DMA fills the upper half of R while the CPU writes all of R whole. */
        flush_dma_region();
        version++;
        uint32_t pattern = 0xD0000000u + (round << 16);
        dma_run(0, DMA_R + DMA_BYTES / 2, DMA_ENGINE_MODE_FILL | burst, pattern);
        write_lines(first, version, round & 2);
        if (dma_engine_wait() & DMA_ENGINE_STATUS_ERROR)
            fail("dma_fill_error", round, 0, 0);
        for (uint32_t line = 0; line < DMA_LINES; line++)
            for (uint32_t dw = 0; dw < 8; dw++) {
                uint64_t got = *(volatile uint64_t *) (DMA_R + 64ul * line + 8ul * dw);
                uint32_t word = (line - DMA_LINES / 2) * 16 + dw * 2;
                uint64_t dma = ((uint64_t) (pattern + word + 1) << 32) | (pattern + word);
                int ok = got == tagged(line, dw, version) || (line >= DMA_LINES / 2 && got == dma);
                if (!ok)
                    fail("final", DMA_R + 64ul * line + 8ul * dw, got, tagged(line, dw, version));
            }
        /* A quiet copy sees what the CPU sees. */
        dma_run(DMA_R, DMA_B, DMA_ENGINE_MODE_COPY | burst, 0);
        dma_engine_wait();
        for (uint32_t i = 0; i < DMA_BYTES / 8; i++) {
            uint64_t want = *(volatile uint64_t *) (DMA_R + 8ul * i);
            uint64_t got = *(volatile uint64_t *) (DMA_B + 8ul * i);
            if (got != want)
                fail("quiet_copy", DMA_B + 8ul * i, got, want);
        }
        /* Whole lines again, written without a fill; a copy reads them exactly. */
        version++;
        write_lines(first, version, 0);
        dma_run(DMA_R, DMA_B, DMA_ENGINE_MODE_COPY | burst, 0);
        dma_engine_wait();
        for (uint32_t line = 0; line < DMA_LINES; line++)
            for (uint32_t dw = 0; dw < 8; dw++) {
                uint64_t got = *(volatile uint64_t *) (DMA_B + 64ul * line + 8ul * dw);
                if (got != tagged(line, dw, version))
                    fail("dma_exact",
                         DMA_B + 64ul * line + 8ul * dw,
                         got,
                         tagged(line, dw, version));
            }
    }
}

int main(void)
{
    csr_write(mtvec, (uintptr_t) skip_trap);
    traps = 0;
    g_failures = 0;
    g_rng = 0x243F6A8885A308D3ull;
    test_streams();
    uart_printf("streams %u\n", g_failures);
    test_squash();
    uart_printf("squash %u\n", g_failures);
    test_order();
    uart_printf("order %u\n", g_failures);
    test_dma();
    uart_printf("dma %u\n", g_failures);
    uart_puts(g_failures ? "<<FAIL>>\n" : "<<PASS>>\n");
    for (;;) {
    }
    return 0;
}
