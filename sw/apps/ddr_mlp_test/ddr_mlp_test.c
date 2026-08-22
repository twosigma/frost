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
 * Two passes over a region larger than the L1D (the sim registry shrinks the
 * L1D to 4 KiB and removes the L2 so the sweep stays short and every miss
 * goes to the DDR model), each touching one word per line so every access
 * is a demand miss:
 *   1. independent loads (a strided sum) -- the load queue may keep several
 *      misses in flight, so L1D_MISS_OVERLAP_CYCLES must be non-zero;
 *   2. a pointer chase through the same lines -- every load depends on the
 *      previous one, so misses serialize and the overlap count stays at
 *      its pass-1 value (the chase is the control).
 * Then a store burst to cold lines: every store misses, and the early
 * acknowledgement lets their fills overlap as well.
 *
 * Results are checked (sums and the chase's final pointer), the cache
 * counters are printed, and <<PASS>> requires overlap to have happened in
 * the independent pass. Cold lines come from a region above the L2.
 */

#include <stdint.h>

#include "tomasulo_profile.h"
#include "uart.h"

#define CACHED_BASE 0x80000000u
#define PROBE_BASE (CACHED_BASE + 0x00600000u) /* 6 MiB in, clear of the program image */
#define LINE_BYTES 32u
#define NUM_LINES 512u /* 16 KiB swept per pass: 4x the sim L1D */

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

/* Read the line-sized counters we care about: local index within the cache block. */
#define L1D_MISS 6u
#define L1D_MISS_CYCLES 13u
#define L1D_OVERLAP 22u

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

    /* Evict everything the seeding left in the L1D by touching a second
     * window of the same size, so both passes start cold. */
    for (i = 0; i < NUM_LINES; i++) {
        (void) probe[(NUM_LINES + i) * (LINE_BYTES / 4u)];
    }

    begin_region();
    got_sum = independent_sum(probe, NUM_LINES);
    end_region();
    ind_miss = cache_delta(L1D_MISS);
    ind_cycles = cache_delta(L1D_MISS_CYCLES);
    ind_overlap = cache_delta(L1D_OVERLAP);
    ind_elapsed = region_cycles();
    uart_printf("independent loads: sum=0x%08x%08x cycles=%lu L1D misses=%lu miss-cycles=%lu "
                "overlap-cycles=%lu\n",
                (uint32_t) (got_sum >> 32),
                (uint32_t) got_sum,
                (unsigned long) ind_elapsed,
                (unsigned long) ind_miss,
                (unsigned long) ind_cycles,
                (unsigned long) ind_overlap);
    if (got_sum != expected_sum) {
        uart_printf("ERROR: independent sum mismatch (expected 0x%08x%08x)\n",
                    (uint32_t) (expected_sum >> 32),
                    (uint32_t) expected_sum);
        failures++;
    }

    for (i = 0; i < NUM_LINES; i++) {
        (void) probe[(NUM_LINES + i) * (LINE_BYTES / 4u)];
    }

    begin_region();
    chase_end = pointer_chase(probe, NUM_LINES);
    end_region();
    chase_miss = cache_delta(L1D_MISS);
    chase_cycles = cache_delta(L1D_MISS_CYCLES);
    chase_overlap = cache_delta(L1D_OVERLAP);
    chase_elapsed = region_cycles();
    uart_printf(
        "pointer chase: end=%lu cycles=%lu L1D misses=%lu miss-cycles=%lu overlap-cycles=%lu\n",
        (unsigned long) chase_end,
        (unsigned long) chase_elapsed,
        (unsigned long) chase_miss,
        (unsigned long) chase_cycles,
        (unsigned long) chase_overlap);
    if (chase_end != 0u) {
        uart_printf("ERROR: chase ended at %lu, expected 0\n", (unsigned long) chase_end);
        failures++;
    }

    for (i = 0; i < NUM_LINES; i++) {
        (void) probe[(NUM_LINES + i) * (LINE_BYTES / 4u)];
    }

    begin_region();
    for (i = 0; i < NUM_LINES; i++) {
        probe[i * (LINE_BYTES / 4u) + 1u] = i;
    }
    end_region();
    store_miss = cache_delta(L1D_MISS);
    store_overlap = cache_delta(L1D_OVERLAP);
    store_elapsed = region_cycles();
    uart_printf("store burst: cycles=%lu L1D misses=%lu overlap-cycles=%lu\n",
                (unsigned long) store_elapsed,
                (unsigned long) store_miss,
                (unsigned long) store_overlap);
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

    if (failures == 0) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("<<FAIL>> failures=%d\n", failures);
    }
    return failures;
}
