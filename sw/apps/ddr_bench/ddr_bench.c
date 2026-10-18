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
 * Memory-bound kernels on cold cached-DDR regions.
 *
 * Each kernel works on a region that nothing touched before, so every line
 * starts outside the L1D and the L2, and prints its cycles and instructions
 * with the cache-counter deltas of its region (zero without PERF_COUNTERS).
 * The program itself runs from BRAM. The kernels:
 *   - seq_read: every word of 1 MiB, in order;
 *   - stride_read: one word in each 32-byte L1 line of 1 MiB;
 *   - streams_read: four interleaved sequential streams of 32 KiB;
 *   - streams_aliased_read: the same four streams 2 MiB apart, the L2's
 *     size, so at every step their lines share one set of the L1D and one
 *     of the L2, which a direct-mapped cache cannot hold;
 *   - random_read: independent single-word loads, spread over 4 MiB;
 *   - record_read: two words, 32 bytes apart, of random 64-byte records;
 *   - chase: loads whose addresses depend on the previous load's value;
 *   - copy: 256 KiB, every word;
 *   - write: 256 KiB, every word.
 * DDR_BENCH_SHIFT divides the sizes and counts by a power of two for
 * simulation. Copy and write check their data afterward.
 */

#include <stdint.h>

#include "tomasulo_profile.h"
#include "uart.h"

#ifndef DDR_BENCH_SHIFT
#define DDR_BENCH_SHIFT 0
#endif

/* The read-only kernels run first, so the writers find no dirty lines left
 * behind. Copy and write share one 2 MiB-aligned window. The copy's
 * destination starts 576 KiB past its source, so each step's source and
 * destination lines share a set of the 4-way L1D (32 KiB ways) and use
 * different L2 sets, and in each set of the L2 (512 KiB ways) the three
 * regions take at most one way each. */
#define CACHED_BASE 0x80000000u
#define MIB (1u << 20)
#define SEQ_READ_BASE (CACHED_BASE + 8u * MIB)
#define STRIDE_BASE (CACHED_BASE + 12u * MIB)
#define STREAMS_BASE (CACHED_BASE + 16u * MIB)
#define RANDOM_BASE (CACHED_BASE + 20u * MIB)
#define RECORD_BASE (CACHED_BASE + 24u * MIB)
#define CHASE_BASE (CACHED_BASE + 28u * MIB)
#define ALIASED_BASE (CACHED_BASE + 40u * MIB)
#define ALIASED_STRIDE (2u * MIB)
#define COPY_SRC_BASE (CACHED_BASE + 32u * MIB)
#define COPY_DST_BASE (CACHED_BASE + 32u * MIB + 576u * 1024u)
#define WRITE_BASE (CACHED_BASE + 33u * MIB)

#define SEQ_READ_BYTES ((1u << 20) >> DDR_BENCH_SHIFT)
#define STREAM_BYTES ((32u << 10) >> DDR_BENCH_SHIFT)
#define RANDOM_READS (4096u >> DDR_BENCH_SHIFT)
#define RECORD_READS (4096u >> DDR_BENCH_SHIFT)
#define CHASE_HOPS (2048u >> DDR_BENCH_SHIFT)
#define COPY_BYTES ((256u << 10) >> DDR_BENCH_SHIFT)
#define WRITE_BYTES ((256u << 10) >> DDR_BENCH_SHIFT)
#define RANDOM_SPAN_WORDS (512u << 10)  /* 4 MiB of 8-byte words */
#define RANDOM_SPAN_RECORDS (64u << 10) /* 4 MiB of 64-byte records */

/* Local indices into the cache-counter block (TOMASULO_PERF_L1I_ACCESS + n). */
#define L1D_MISS 6u
#define L2_ACCESS 8u
#define L2_MISS 10u
#define L2_WRITEBACK 11u
#define L2_MISS_CYCLES 14u
#define L2_FULL_STALL 19u
#define L2_CONFLICT_STALL 21u
#define L2_OVERLAP 23u

static tomasulo_profile_snapshot_t snap_start;
static tomasulo_profile_snapshot_t snap_end;
static uint64_t cache_start[TOMASULO_PROFILE_CACHE_COUNTER_COUNT];
static uint64_t cache_end[TOMASULO_PROFILE_CACHE_COUNTER_COUNT];

static uint64_t cache_delta(uint32_t local_index)
{
    return cache_end[local_index] - cache_start[local_index];
}

static void begin_region(void)
{
    tomasulo_profile_bind_cache_counters(&snap_start, cache_start);
    tomasulo_profile_bind_cache_counters(&snap_end, cache_end);
    tomasulo_profile_take_snapshot(&snap_start);
}

static void end_region(const char *name)
{
    tomasulo_profile_take_snapshot(&snap_end);
    tomasulo_profile_read_cache_pair(&snap_start, &snap_end);
    uart_printf("KERNEL %s cycles=%lu instret=%lu l1d_miss=%lu l2_access=%lu l2_miss=%lu "
                "l2_wb=%lu l2_miss_cycles=%lu l2_overlap=%lu l2_full_stall=%lu "
                "l2_conflict_stall=%lu\n",
                name,
                (unsigned long) (snap_end.cycles - snap_start.cycles),
                (unsigned long) (snap_end.instret - snap_start.instret),
                (unsigned long) cache_delta(L1D_MISS),
                (unsigned long) cache_delta(L2_ACCESS),
                (unsigned long) cache_delta(L2_MISS),
                (unsigned long) cache_delta(L2_WRITEBACK),
                (unsigned long) cache_delta(L2_MISS_CYCLES),
                (unsigned long) cache_delta(L2_OVERLAP),
                (unsigned long) cache_delta(L2_FULL_STALL),
                (unsigned long) cache_delta(L2_CONFLICT_STALL));
}

static inline uint32_t xorshift32(uint32_t x)
{
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x;
}

/* The read kernels return a sum so the compiler keeps their loads. */
static volatile uint64_t sink;

__attribute__((noinline)) static uint64_t seq_read(volatile uint64_t *p, uint32_t words)
{
    uint64_t a = 0, b = 0, c = 0, d = 0;
    for (uint32_t i = 0; i < words; i += 4) {
        a += p[i];
        b += p[i + 1];
        c += p[i + 2];
        d += p[i + 3];
    }
    return a + b + c + d;
}

__attribute__((noinline)) static uint64_t stride_read(volatile uint64_t *p, uint32_t lines)
{
    uint64_t a = 0, b = 0, c = 0, d = 0;
    for (uint32_t i = 0; i < lines; i += 4) {
        a += p[(i + 0) * 4u];
        b += p[(i + 1) * 4u];
        c += p[(i + 2) * 4u];
        d += p[(i + 3) * 4u];
    }
    return a + b + c + d;
}

__attribute__((noinline)) static uint64_t streams_read(volatile uint64_t *p0,
                                                       volatile uint64_t *p1,
                                                       volatile uint64_t *p2,
                                                       volatile uint64_t *p3,
                                                       uint32_t words)
{
    uint64_t a = 0, b = 0, c = 0, d = 0;
    for (uint32_t i = 0; i < words; i++) {
        a += p0[i];
        b += p1[i];
        c += p2[i];
        d += p3[i];
    }
    return a + b + c + d;
}

__attribute__((noinline)) static uint64_t random_read(volatile uint64_t *p, uint32_t reads)
{
    uint64_t a = 0, b = 0;
    uint32_t x = 0x1234567u, y = 0x89abcdefu;
    for (uint32_t i = 0; i < reads; i += 2) {
        x = xorshift32(x);
        y = xorshift32(y);
        a += p[x & (RANDOM_SPAN_WORDS - 1u)];
        b += p[y & (RANDOM_SPAN_WORDS - 1u)];
    }
    return a + b;
}

/* Words 0 and 4 of a 64-byte record are in different 32-byte L1 lines of
 * one 64-byte L2 line. */
__attribute__((noinline)) static uint64_t record_read(volatile uint64_t *p, uint32_t reads)
{
    uint64_t a = 0, b = 0;
    uint32_t x = 0x2468aceu;
    for (uint32_t i = 0; i < reads; i++) {
        x = xorshift32(x);
        volatile uint64_t *record = p + (x & (RANDOM_SPAN_RECORDS - 1u)) * 8u;
        a += record[0];
        b += record[4];
    }
    return a + b;
}

/* Each address depends on the value the previous load returned, so the
 * misses cannot overlap. */
__attribute__((noinline)) static uint64_t chase(volatile uint64_t *p, uint32_t hops)
{
    uint32_t x = 0x13579bdu;
    for (uint32_t i = 0; i < hops; i++) {
        x = xorshift32(x ^ (uint32_t) p[x & (RANDOM_SPAN_WORDS - 1u)]);
    }
    return x;
}

__attribute__((noinline)) static void
copy(volatile uint64_t *dst, volatile uint64_t *src, uint32_t words)
{
    for (uint32_t i = 0; i < words; i += 4) {
        uint64_t a = src[i], b = src[i + 1], c = src[i + 2], d = src[i + 3];
        dst[i] = a;
        dst[i + 1] = b;
        dst[i + 2] = c;
        dst[i + 3] = d;
    }
}

/* Each group of four words holds the index of its first word. */
__attribute__((noinline)) static void write(volatile uint64_t *p, uint32_t words)
{
    for (uint32_t i = 0; i < words; i += 4) {
        p[i] = i;
        p[i + 1] = i;
        p[i + 2] = i;
        p[i + 3] = i;
    }
}

int main(void)
{
    volatile uint64_t *const copy_src = (volatile uint64_t *) COPY_SRC_BASE;
    volatile uint64_t *const copy_dst = (volatile uint64_t *) COPY_DST_BASE;
    volatile uint64_t *const write_dst = (volatile uint64_t *) WRITE_BASE;
    uint32_t failures = 0;

    uart_printf("DDR bench, sizes divided by %u\n", 1u << DDR_BENCH_SHIFT);
    tomasulo_profile_print_presence();

    begin_region();
    sink = seq_read((volatile uint64_t *) SEQ_READ_BASE, SEQ_READ_BYTES / 8u);
    end_region("seq_read");

    begin_region();
    sink = stride_read((volatile uint64_t *) STRIDE_BASE, SEQ_READ_BYTES / 32u);
    end_region("stride_read");

    begin_region();
    /* The streams sit in the four quarters of one 128 KiB-aligned window: one
     * set of the 4-way L1D (32 KiB ways) holds a line of each, and they use
     * different L2 sets. */
    sink = streams_read((volatile uint64_t *) STREAMS_BASE,
                        (volatile uint64_t *) (STREAMS_BASE + 0x8000u),
                        (volatile uint64_t *) (STREAMS_BASE + 0x10000u),
                        (volatile uint64_t *) (STREAMS_BASE + 0x18000u),
                        STREAM_BYTES / 8u);
    end_region("streams_read");

    begin_region();
    sink = streams_read((volatile uint64_t *) ALIASED_BASE,
                        (volatile uint64_t *) (ALIASED_BASE + ALIASED_STRIDE),
                        (volatile uint64_t *) (ALIASED_BASE + 2u * ALIASED_STRIDE),
                        (volatile uint64_t *) (ALIASED_BASE + 3u * ALIASED_STRIDE),
                        STREAM_BYTES / 8u);
    end_region("streams_aliased_read");

    begin_region();
    sink = random_read((volatile uint64_t *) RANDOM_BASE, RANDOM_READS);
    end_region("random_read");

    begin_region();
    sink = record_read((volatile uint64_t *) RECORD_BASE, RECORD_READS);
    end_region("record_read");

    begin_region();
    sink = chase((volatile uint64_t *) CHASE_BASE, CHASE_HOPS);
    end_region("chase");

    begin_region();
    copy(copy_dst, copy_src, COPY_BYTES / 8u);
    end_region("copy");

    begin_region();
    write(write_dst, WRITE_BYTES / 8u);
    end_region("write");

    for (uint32_t i = 0; i < COPY_BYTES / 8u; i++) {
        if (copy_dst[i] != copy_src[i]) {
            uart_printf("ERROR: copy word %lu differs\n", (unsigned long) i);
            failures++;
            break;
        }
    }
    for (uint32_t i = 0; i < WRITE_BYTES / 8u; i++) {
        if (write_dst[i] != (i & ~3u)) {
            uart_printf("ERROR: write word %lu reads back wrong\n", (unsigned long) i);
            failures++;
            break;
        }
    }

    if (failures == 0) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("<<FAIL>>\n");
    }
    return (int) failures;
}
