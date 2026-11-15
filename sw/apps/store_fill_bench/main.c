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

/*
 * Store-stream benchmark: cycles to write cached DDR with the store patterns
 * of Linux's memset, copy_from_user (fallback_scalar_usercopy's word loop:
 * eight ld then eight sd per 64-byte block) and clear_page (cbo.zero per
 * block), against partial-line and interleaved-load variants. Each kernel
 * runs on a region not touched since reset (cold: the L1D and L2 miss and
 * DDR holds the old contents) and again after the region was written and
 * then evicted from the L1D by a read sweep (l2: the L2 holds the lines).
 * Each timed kernel ends with a fence, so the count includes draining the
 * store queue and the L1D's store records.
 *
 * Every kernel writes a nonzero, address-dependent pattern (cbo.zero writes
 * zeros), and the program checks every byte of every region afterwards,
 * including the bytes that the partial kernels leave unwritten, which must
 * keep their previous contents.
 *
 * Output lines: "FROST_STORE_BENCH <kernel> <cold|l2> bytes=<n> cycles=<n>
 * l1d_misses=<n> sq_full=<n>", the last two from the fixed counters
 * mhpmcounter7 (L1D permission misses) and mhpmcounter8 (store-queue-full
 * stall cycles). STORE_BENCH_ONLY=<k> runs only kernel k (0 memset_sd,
 * 1 memset_sw, 2 partial48, 3 memcpy, 4 memcpy_ld, 5 cbo_zero), at the first
 * region.
 */

#include <stdint.h>

#include "uart.h"

#ifndef STORE_BENCH_BASE
#define STORE_BENCH_BASE 0x82000000ul
#endif
#ifndef STORE_BENCH_BYTES
#define STORE_BENCH_BYTES (64ul << 10)
#endif
/* The read sweep that evicts a region from the L1D before the l2 pass. */
#ifndef STORE_BENCH_EVICT_BYTES
#define STORE_BENCH_EVICT_BYTES (256ul << 10)
#endif

#define BLOCK 64ul
#define SRC_BYTES (16ul << 10)

/* The copy source, in cached DDR below the regions; it stays in the L1D. */
#define src_buf ((uint64_t *) (STORE_BENCH_BASE - SRC_BYTES))

static inline unsigned long rdcycle_now(void)
{
    unsigned long c;
    __asm__ volatile("rdcycle %0" : "=r"(c));
    return c;
}

static inline unsigned long l1d_misses_now(void)
{
    unsigned long c;
    __asm__ volatile("csrr %0, 0xB07" : "=r"(c));
    return c;
}

static inline unsigned long sq_full_now(void)
{
    unsigned long c;
    __asm__ volatile("csrr %0, 0xB08" : "=r"(c));
    return c;
}

static unsigned long last_misses, last_sq_full;

static inline uint64_t pattern(unsigned long addr, uint64_t salt)
{
    return (addr * 0x9E3779B97F4A7C15ul) ^ salt;
}

/* memset-like: eight sd of one value per block. */
static void k_memset_sd(unsigned long base, unsigned long bytes, uint64_t value)
{
    unsigned long end = base + bytes;
    __asm__ volatile("1:\n"
                     "sd   %2, 0(%0)\n"
                     "sd   %2, 8(%0)\n"
                     "sd   %2, 16(%0)\n"
                     "sd   %2, 24(%0)\n"
                     "sd   %2, 32(%0)\n"
                     "sd   %2, 40(%0)\n"
                     "sd   %2, 48(%0)\n"
                     "sd   %2, 56(%0)\n"
                     "addi %0, %0, 64\n"
                     "bltu %0, %1, 1b\n"
                     "fence rw, rw\n"
                     : "+r"(base)
                     : "r"(end), "r"(value)
                     : "memory");
}

/* memset with word stores: sixteen sw per block. */
static void k_memset_sw(unsigned long base, unsigned long bytes, uint64_t value)
{
    unsigned long end = base + bytes;
    __asm__ volatile("1:\n"
                     "sw   %2, 0(%0)\n"
                     "sw   %2, 4(%0)\n"
                     "sw   %2, 8(%0)\n"
                     "sw   %2, 12(%0)\n"
                     "sw   %2, 16(%0)\n"
                     "sw   %2, 20(%0)\n"
                     "sw   %2, 24(%0)\n"
                     "sw   %2, 28(%0)\n"
                     "sw   %2, 32(%0)\n"
                     "sw   %2, 36(%0)\n"
                     "sw   %2, 40(%0)\n"
                     "sw   %2, 44(%0)\n"
                     "sw   %2, 48(%0)\n"
                     "sw   %2, 52(%0)\n"
                     "sw   %2, 56(%0)\n"
                     "sw   %2, 60(%0)\n"
                     "addi %0, %0, 64\n"
                     "bltu %0, %1, 1b\n"
                     "fence rw, rw\n"
                     : "+r"(base)
                     : "r"(end), "r"(value)
                     : "memory");
}

/* Partial lines: the first 48 bytes of each block (a full lower sector and
 * half of the upper one). */
static void k_partial48(unsigned long base, unsigned long bytes, uint64_t value)
{
    unsigned long end = base + bytes;
    __asm__ volatile("1:\n"
                     "sd   %2, 0(%0)\n"
                     "sd   %2, 8(%0)\n"
                     "sd   %2, 16(%0)\n"
                     "sd   %2, 24(%0)\n"
                     "sd   %2, 32(%0)\n"
                     "sd   %2, 40(%0)\n"
                     "addi %0, %0, 64\n"
                     "bltu %0, %1, 1b\n"
                     "fence rw, rw\n"
                     : "+r"(base)
                     : "r"(end), "r"(value)
                     : "memory");
}

/* copy_from_user's word loop: eight ld, then eight sd, per block. The source
 * is a 16 KiB buffer, read repeatedly, that stays in the L1D. */
static void k_memcpy(unsigned long dst, unsigned long bytes)
{
    unsigned long end = dst + bytes;
    unsigned long src = (unsigned long) src_buf;
    unsigned long src_end = src + SRC_BYTES;
    __asm__ volatile("1:\n"
                     "ld   t0, 0(%1)\n"
                     "ld   t1, 8(%1)\n"
                     "ld   t2, 16(%1)\n"
                     "ld   t3, 24(%1)\n"
                     "ld   t4, 32(%1)\n"
                     "ld   t5, 40(%1)\n"
                     "ld   t6, 48(%1)\n"
                     "ld   a7, 56(%1)\n"
                     "sd   t0, 0(%0)\n"
                     "sd   t1, 8(%0)\n"
                     "sd   t2, 16(%0)\n"
                     "sd   t3, 24(%0)\n"
                     "sd   t4, 32(%0)\n"
                     "sd   t5, 40(%0)\n"
                     "sd   t6, 48(%0)\n"
                     "sd   a7, 56(%0)\n"
                     "addi %0, %0, 64\n"
                     "addi %1, %1, 64\n"
                     "bltu %1, %3, 2f\n"
                     "sub  %1, %1, %4\n"
                     "2:\n"
                     "bltu %0, %2, 1b\n"
                     "fence rw, rw\n"
                     : "+r"(dst), "+r"(src)
                     : "r"(end), "r"(src_end), "r"(SRC_BYTES)
                     : "t0", "t1", "t2", "t3", "t4", "t5", "t6", "a7", "memory");
}

/* The memcpy loop with a load of the block just written after its eight
 * stores, and a load of the next block's first dword before them. */
static void k_memcpy_interleaved(unsigned long dst, unsigned long bytes, uint64_t *sink)
{
    unsigned long end = dst + bytes;
    unsigned long src = (unsigned long) src_buf;
    unsigned long src_end = src + SRC_BYTES;
    uint64_t acc = 0;
    __asm__ volatile("1:\n"
                     "ld   t0, 0(%1)\n"
                     "ld   t1, 8(%1)\n"
                     "ld   t2, 16(%1)\n"
                     "ld   t3, 24(%1)\n"
                     "ld   t4, 32(%1)\n"
                     "ld   t5, 40(%1)\n"
                     "ld   t6, 48(%1)\n"
                     "ld   a7, 56(%1)\n"
                     "sd   t0, 0(%0)\n"
                     "sd   t1, 8(%0)\n"
                     "sd   t2, 16(%0)\n"
                     "ld   a6, 64(%0)\n"
                     "sd   t3, 24(%0)\n"
                     "sd   t4, 32(%0)\n"
                     "sd   t5, 40(%0)\n"
                     "sd   t6, 48(%0)\n"
                     "sd   a7, 56(%0)\n"
                     "ld   a5, 8(%0)\n"
                     "add  %2, %2, a5\n"
                     "add  %2, %2, a6\n"
                     "addi %0, %0, 64\n"
                     "addi %1, %1, 64\n"
                     "bltu %1, %4, 2f\n"
                     "sub  %1, %1, %5\n"
                     "2:\n"
                     "bltu %0, %3, 1b\n"
                     "fence rw, rw\n"
                     : "+r"(dst), "+r"(src), "+r"(acc)
                     : "r"(end), "r"(src_end), "r"(SRC_BYTES)
                     : "t0", "t1", "t2", "t3", "t4", "t5", "t6", "a5", "a6", "a7", "memory");
    *sink = acc;
}

/* clear_page: sixteen cbo.zero per iteration. */
static void k_cbo_zero(unsigned long base, unsigned long bytes)
{
    unsigned long end = base + bytes;
    __asm__ volatile("1:\n"
                     ".insn i 0x0F, 2, x0, %0, 4\n"
                     "addi %0, %0, 64\n"
                     ".insn i 0x0F, 2, x0, %0, 4\n"
                     "addi %0, %0, 64\n"
                     ".insn i 0x0F, 2, x0, %0, 4\n"
                     "addi %0, %0, 64\n"
                     ".insn i 0x0F, 2, x0, %0, 4\n"
                     "addi %0, %0, 64\n"
                     "bltu %0, %1, 1b\n"
                     "fence rw, rw\n"
                     : "+r"(base)
                     : "r"(end)
                     : "memory");
}

/* Background contents that a partial kernel must keep. */
static void fill_background(unsigned long base, unsigned long bytes, uint64_t salt)
{
    for (unsigned long a = base; a < base + bytes; a += 8)
        *(volatile uint64_t *) a = pattern(a, salt);
}

static void evict_l1d(unsigned long base)
{
    uint64_t acc = 0;
    for (unsigned long a = base; a < base + STORE_BENCH_EVICT_BYTES; a += 32)
        acc += *(volatile uint64_t *) a;
    __asm__ volatile("" ::"r"(acc));
}

enum kernel { K_MEMSET_SD, K_MEMSET_SW, K_PARTIAL48, K_MEMCPY, K_MEMCPY_LD, K_CBO_ZERO, K_COUNT };

static const char *const kernel_names[K_COUNT] = {
    "memset_sd", "memset_sw", "partial48", "memcpy", "memcpy_ld", "cbo_zero"};

static uint64_t expected(enum kernel k, unsigned long a, uint64_t value, uint64_t background_salt)
{
    unsigned long off = a & (BLOCK - 1);
    switch (k) {
        case K_MEMSET_SD:
            return value;
        case K_MEMSET_SW:
            return (value & 0xFFFFFFFFul) | ((value & 0xFFFFFFFFul) << 32);
        case K_PARTIAL48:
            return off < 48 ? value : pattern(a, background_salt);
        case K_MEMCPY:
        case K_MEMCPY_LD:
            return src_buf[(a % SRC_BYTES) / 8];
        case K_CBO_ZERO:
        default:
            return 0;
    }
}

static unsigned long run_kernel(enum kernel k, unsigned long base, uint64_t value)
{
    uint64_t sink = 0;
    unsigned long misses = l1d_misses_now();
    unsigned long sq_full = sq_full_now();
    unsigned long start = rdcycle_now();
    switch (k) {
        case K_MEMSET_SD:
            k_memset_sd(base, STORE_BENCH_BYTES, value);
            break;
        case K_MEMSET_SW:
            k_memset_sw(base, STORE_BENCH_BYTES, value);
            break;
        case K_PARTIAL48:
            k_partial48(base, STORE_BENCH_BYTES, value);
            break;
        case K_MEMCPY:
            k_memcpy(base, STORE_BENCH_BYTES);
            break;
        case K_MEMCPY_LD:
            k_memcpy_interleaved(base, STORE_BENCH_BYTES, &sink);
            break;
        case K_CBO_ZERO:
        default:
            k_cbo_zero(base, STORE_BENCH_BYTES);
            break;
    }
    unsigned long cycles = rdcycle_now() - start;
    last_misses = l1d_misses_now() - misses;
    last_sq_full = sq_full_now() - sq_full;
    __asm__ volatile("" ::"r"(sink));
    return cycles;
}

static int check(enum kernel k, unsigned long base, uint64_t value, uint64_t background_salt)
{
    unsigned long bad = 0;
    for (unsigned long a = base; a < base + STORE_BENCH_BYTES; a += 8) {
        uint64_t got = *(volatile uint64_t *) a;
        uint64_t want = expected(k, a, value, background_salt);
        if (got != want) {
            if (bad < 4)
                uart_printf("MISMATCH %s at %lx: got %lx want %lx\r\n",
                            kernel_names[k],
                            a,
                            (unsigned long) got,
                            (unsigned long) want);
            bad++;
        }
    }
    return bad == 0;
}

int main(void)
{
    int ok = 1;
    unsigned long base = STORE_BENCH_BASE;
    const unsigned long evict = base;
    base += STORE_BENCH_EVICT_BYTES;

    uart_puts("\r\n=== store-stream benchmark ===\r\n");
    __asm__ volatile("csrw mcountinhibit, zero");
    for (unsigned long i = 0; i < SRC_BYTES / 8; i++)
        src_buf[i] = pattern((unsigned long) &src_buf[i], 0x5151515151515151ul);
    evict_l1d(evict);

#ifdef STORE_BENCH_ONLY
    for (int k = STORE_BENCH_ONLY; k == STORE_BENCH_ONLY; k++) {
#else
    for (int k = 0; k < K_COUNT; k++) {
#endif
        for (int pass = 0; pass < 2; pass++) {
            uint64_t value = pattern(base + (unsigned long) pass, 0xA5A5A5A5A5A5A5A5ul) | 1;
            uint64_t background_salt = 0x3C3C3C3C3C3C3C3Cul + (uint64_t) k;
            if (pass == 1) {
                /* The l2 pass: the region holds a known background, written
                 * and then evicted from the L1D, so the L2 holds it. */
                fill_background(base, STORE_BENCH_BYTES, background_salt);
                evict_l1d(evict);
            }
            unsigned long cycles = run_kernel((enum kernel) k, base, value);
            int good;
            if (k == K_PARTIAL48 && pass == 0) {
                /* Cold: only the written bytes have a known value. */
                unsigned long bad = 0;
                for (unsigned long a = base; a < base + STORE_BENCH_BYTES; a += 8)
                    if ((a & (BLOCK - 1)) < 48 && *(volatile uint64_t *) a != value)
                        bad++;
                good = bad == 0;
            } else {
                good = check((enum kernel) k, base, value, background_salt);
            }
            ok &= good;
            uart_printf(
                "FROST_STORE_BENCH %s %s bytes=%lu cycles=%lu l1d_misses=%lu sq_full=%lu%s\r\n",
                kernel_names[k],
                pass ? "l2" : "cold",
                STORE_BENCH_BYTES,
                cycles,
                last_misses,
                last_sq_full,
                good ? "" : " MISMATCH");
        }
        base += STORE_BENCH_BYTES;
    }

    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
