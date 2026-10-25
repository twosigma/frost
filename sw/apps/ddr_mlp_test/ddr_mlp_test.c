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
 * Memory-level parallelism probe for the cached (DDR) tier.
 *
 * Sweep a region with independent loads, then a dependent pointer chase,
 * then cold stores. Evict the region before each pass. The default eviction
 * window targets 4 KiB caches. DDR_MLP_FULL_CACHE uses conflicting sets in
 * the 128 KiB L1D and 2 MiB L2.
 *
 * Check the sum, final pointer, and sampled stores. Passing requires misses
 * on at least half the independent loads, overlapping misses in the
 * independent-load and store passes, and fewer cycles for independent loads
 * than for the chase. Full-cache mode also checks aggregate L2 miss traffic.
 * Report each pass's cache-counter deltas; the chase is the serialized
 * control.
 */

#include <stdint.h>

#include "cache_evict.h"
#include "tomasulo_profile.h"
#include "uart.h"

#define CACHED_BASE 0x80000000u
#define PROBE_BASE (CACHED_BASE + 0x00600000u) /* 6 MiB in, clear of the program image */
#define LINE_BYTES 32u
#define NUM_LINES 512u /* 16 KiB swept per pass. */

#ifndef DDR_MLP_FULL_CACHE
#define DDR_MLP_FULL_CACHE 0
#endif

static tomasulo_profile_snapshot_t snap_start;
static tomasulo_profile_snapshot_t snap_end;
static uint64_t cache_start[TOMASULO_PROFILE_CACHE_COUNTER_COUNT];
static uint64_t cache_end[TOMASULO_PROFILE_CACHE_COUNTER_COUNT];

static uint64_t cache_delta(uint32_t local_index)
{
    return cache_end[local_index] - cache_start[local_index];
}

static uint64_t region_cycles(void)
{
    return snap_end.cycles - snap_start.cycles;
}

static void begin_region(void)
{
    tomasulo_profile_bind_cache_counters(&snap_start, cache_start);
    tomasulo_profile_bind_cache_counters(&snap_end, cache_end);
    tomasulo_profile_take_snapshot(&snap_start);
}

static void end_region(void)
{
    tomasulo_profile_take_snapshot(&snap_end);
    tomasulo_profile_read_cache_pair(&snap_start, &snap_end);
}

/* Local indices into the cache-counter block, which starts at TOMASULO_PERF_L1I_ACCESS. */
#define L1D_MISS 6u
#define L1D_MISS_CYCLES 13u
#define L1D_OVERLAP 22u
#define L2_MISS 10u

static void evict_probe(void)
{
#if DDR_MLP_FULL_CACHE
    static uint32_t pass;
    /* Write dirty probe data to L2 before the alias reads. */
    __asm__ volatile("fence.i" ::: "memory");
    uint32_t first_way = pass++ * CACHE_EVICTING_LINES;
    /* Each pass touches a distinct group of alias windows. */
    for (uint32_t way = 1; way <= CACHE_EVICTING_LINES; way++) {
        for (uint32_t i = 0; i < NUM_LINES; i++) {
            (void) cache_touch_line(PROBE_BASE + (first_way + way) * CACHE_L2_WAY_BYTES +
                                    i * LINE_BYTES);
        }
    }
#else
    for (uint32_t i = 0; i < NUM_LINES; i++) {
        (void) cache_touch_line(PROBE_BASE + (NUM_LINES + i) * LINE_BYTES);
    }
#endif
}

__attribute__((noinline)) static uint64_t independent_sum(volatile uint32_t *base, uint32_t lines)
{
    uint64_t sum = 0;
    uint32_t i;

    /* Four independent accumulators so the compiler keeps the loads
     * independent and the load queue can launch several at once. */
    uint64_t a = 0, b = 0, c = 0, d = 0;
    for (i = 0; i + 4 <= lines; i += 4) {
        a += base[(i + 0) * (LINE_BYTES / 4u)];
        b += base[(i + 1) * (LINE_BYTES / 4u)];
        c += base[(i + 2) * (LINE_BYTES / 4u)];
        d += base[(i + 3) * (LINE_BYTES / 4u)];
    }
    sum = a + b + c + d;
    return sum;
}

__attribute__((noinline)) static uint32_t pointer_chase(volatile uint32_t *base, uint32_t lines)
{
    uint32_t idx = 0;
    uint32_t i;
    for (i = 0; i < lines; i++) {
        idx = base[idx * (LINE_BYTES / 4u)];
    }
    return idx;
}

int main(void)
{
    volatile uint32_t *const probe = (volatile uint32_t *) PROBE_BASE;
    uint32_t i;
    uint64_t expected_sum = 0;
    uint64_t got_sum;
    uint32_t chase_end;
    uint64_t ind_miss, ind_overlap, ind_cycles, ind_elapsed;
    uint64_t chase_miss, chase_overlap, chase_cycles, chase_elapsed;
    uint64_t store_miss, store_overlap, store_elapsed;
    uint64_t ind_l2_miss, chase_l2_miss, store_l2_miss;
    int failures = 0;

    uart_printf("DDR memory-level-parallelism probe\n");
    uart_printf("==================================\n");

    /* Seed: word 0 of line i holds the next line of the chase (i+1 mod N)
     * and also contributes to the independent sum. Stores miss too. */
    for (i = 0; i < NUM_LINES; i++) {
        uint32_t next = (i + 1u) % NUM_LINES;
        probe[i * (LINE_BYTES / 4u)] = next;
        expected_sum += next;
    }

    /* Each conflicting line is read and then hit to advance L1D replacement. */
    evict_probe();

    begin_region();
    got_sum = independent_sum(probe, NUM_LINES);
    end_region();
    ind_miss = cache_delta(L1D_MISS);
    ind_cycles = cache_delta(L1D_MISS_CYCLES);
    ind_overlap = cache_delta(L1D_OVERLAP);
    ind_elapsed = region_cycles();
    ind_l2_miss = cache_delta(L2_MISS);
    uart_printf("independent loads: sum=0x%08x%08x cycles=%lu L1D misses=%lu miss-cycles=%lu "
                "overlap-cycles=%lu\n",
                (uint32_t) (got_sum >> 32),
                (uint32_t) got_sum,
                (unsigned long) ind_elapsed,
                (unsigned long) ind_miss,
                (unsigned long) ind_cycles,
                (unsigned long) ind_overlap);
    uart_printf("independent loads: L2 misses=%lu\n", (unsigned long) ind_l2_miss);
    if (got_sum != expected_sum) {
        uart_printf("ERROR: independent sum mismatch (expected 0x%08x%08x)\n",
                    (uint32_t) (expected_sum >> 32),
                    (uint32_t) expected_sum);
        failures++;
    }

    evict_probe();

    begin_region();
    chase_end = pointer_chase(probe, NUM_LINES);
    end_region();
    chase_miss = cache_delta(L1D_MISS);
    chase_cycles = cache_delta(L1D_MISS_CYCLES);
    chase_overlap = cache_delta(L1D_OVERLAP);
    chase_elapsed = region_cycles();
    chase_l2_miss = cache_delta(L2_MISS);
    uart_printf(
        "pointer chase: end=%lu cycles=%lu L1D misses=%lu miss-cycles=%lu overlap-cycles=%lu\n",
        (unsigned long) chase_end,
        (unsigned long) chase_elapsed,
        (unsigned long) chase_miss,
        (unsigned long) chase_cycles,
        (unsigned long) chase_overlap);
    uart_printf("pointer chase: L2 misses=%lu\n", (unsigned long) chase_l2_miss);
    if (chase_end != 0u) {
        uart_printf("ERROR: chase ended at %lu, expected 0\n", (unsigned long) chase_end);
        failures++;
    }

    evict_probe();

    begin_region();
    for (i = 0; i < NUM_LINES; i++) {
        probe[i * (LINE_BYTES / 4u) + 1u] = i;
    }
    end_region();
    store_miss = cache_delta(L1D_MISS);
    store_overlap = cache_delta(L1D_OVERLAP);
    store_elapsed = region_cycles();
    store_l2_miss = cache_delta(L2_MISS);
    uart_printf("store burst: cycles=%lu L1D misses=%lu overlap-cycles=%lu\n",
                (unsigned long) store_elapsed,
                (unsigned long) store_miss,
                (unsigned long) store_overlap);
    uart_printf("store burst: L2 misses=%lu\n", (unsigned long) store_l2_miss);
    for (i = 0; i < NUM_LINES; i += 97u) {
        if (probe[i * (LINE_BYTES / 4u) + 1u] != i) {
            uart_printf("ERROR: store burst readback mismatch at line %lu\n", (unsigned long) i);
            failures++;
        }
    }

    if (ind_miss < NUM_LINES / 2u) {
        uart_printf("ERROR: the independent pass did not miss (%lu)\n", (unsigned long) ind_miss);
        failures++;
    }
    if (ind_overlap == 0u) {
        uart_printf("ERROR: no overlapped demand misses in the independent pass\n");
        failures++;
    }
    if (ind_elapsed >= chase_elapsed) {
        uart_printf("ERROR: independent loads were no faster than the serialized chase\n");
        failures++;
    }
    if (store_overlap == 0u) {
        uart_printf("ERROR: no overlapped store misses\n");
        failures++;
    }
    if (DDR_MLP_FULL_CACHE && (ind_l2_miss < NUM_LINES / 2u || chase_l2_miss < NUM_LINES / 2u ||
                               store_l2_miss < NUM_LINES / 2u)) {
        uart_printf("ERROR: a full-cache pass did not miss in L2\n");
        failures++;
    }

    if (failures == 0) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("<<FAIL>> failures=%d\n", failures);
    }
    return failures;
}
