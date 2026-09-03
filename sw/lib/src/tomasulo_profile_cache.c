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

#include "tomasulo_profile.h"

/*
 * This code runs only after a measured region ends. Its own linker sections
 * sit after the legacy program image, so adding it leaves the code and data
 * addresses at the timing boundary unchanged, and with them the warm
 * microarchitectural state.
 */
#define CACHE_PROFILE_TEXT __attribute__((section(".cache_profile_text")))
#define CACHE_PROFILE_RODATA __attribute__((section(".cache_profile_rodata"), aligned(1)))

extern tomasulo_profile_snapshot_t tomasulo_profile_default_report_start __attribute__((weak));
extern tomasulo_profile_snapshot_t tomasulo_profile_default_report_end __attribute__((weak));

static const char metric_prefix[] CACHE_PROFILE_RODATA = "  %s: ";
static const char u64_hex_format[] CACHE_PROFILE_RODATA = "0x%08x%08x";
static const char metric_suffix[] CACHE_PROFILE_RODATA = " (%lu.%01lu%%)\n";
static const char no_accesses[] CACHE_PROFILE_RODATA = "  %s hit rate: n/a (no accesses)\n";
static const char hit_rate[] CACHE_PROFILE_RODATA = "  %s hit rate: %lu.%01lu%%\n";
static const char no_misses[] CACHE_PROFILE_RODATA = "  %s average miss latency: n/a (no misses)\n";
static const char miss_latency[] CACHE_PROFILE_RODATA =
    "  %s average miss latency: %lu.%02lu cycles\n";
static const char cache_header[] CACHE_PROFILE_RODATA = "  Cache hierarchy:\n";
static const char diagnostic_header[] CACHE_PROFILE_RODATA = "  Diagnostic counters:\n";
static const char l1i[] CACHE_PROFILE_RODATA = "L1I";
static const char l1i_access_label[] CACHE_PROFILE_RODATA = "L1I access";
static const char l1i_hit_label[] CACHE_PROFILE_RODATA = "L1I hit";
static const char l1i_miss_label[] CACHE_PROFILE_RODATA = "L1I miss";
static const char l1i_writeback_label[] CACHE_PROFILE_RODATA = "L1I dirty-victim writeback";
static const char l1d[] CACHE_PROFILE_RODATA = "L1D";
static const char l1d_access_label[] CACHE_PROFILE_RODATA = "L1D access";
static const char l1d_hit_label[] CACHE_PROFILE_RODATA = "L1D hit";
static const char l1d_miss_label[] CACHE_PROFILE_RODATA = "L1D miss";
static const char l1d_writeback_label[] CACHE_PROFILE_RODATA = "L1D dirty-victim writeback";
static const char l2[] CACHE_PROFILE_RODATA = "L2";
static const char l2_access_label[] CACHE_PROFILE_RODATA = "L2 access";
static const char l2_hit_label[] CACHE_PROFILE_RODATA = "L2 hit";
static const char l2_miss_label[] CACHE_PROFILE_RODATA = "L2 miss";
static const char l2_writeback_label[] CACHE_PROFILE_RODATA = "L2 dirty-victim writeback";
static const char l1i_stall_label[] CACHE_PROFILE_RODATA = "L1I fetch-miss stall";
static const char l1i_hum_label[] CACHE_PROFILE_RODATA = "L1I hit under miss";
static const char l1d_hum_label[] CACHE_PROFILE_RODATA = "L1D hit under miss";
static const char l2_hum_label[] CACHE_PROFILE_RODATA = "L2 hit under miss";
static const char l1d_full_label[] CACHE_PROFILE_RODATA = "L1D slot-full stall";
static const char l2_full_label[] CACHE_PROFILE_RODATA = "L2 slot-full stall";
static const char l1d_conflict_label[] CACHE_PROFILE_RODATA = "L1D index-conflict stall";
static const char l2_conflict_label[] CACHE_PROFILE_RODATA = "L2 index-conflict stall";
static const char l1d_overlap_label[] CACHE_PROFILE_RODATA = "L1D >=2 misses in flight";
static const char l2_overlap_label[] CACHE_PROFILE_RODATA = "L2 >=2 misses in flight";

static CACHE_PROFILE_TEXT void read_cache_bank(uint64_t *cache_counters, uint32_t control)
{
    uint32_t i;

    csr_write_imm(CSR_MPERFCTL, control);
    for (i = 0; i < TOMASULO_PROFILE_CACHE_COUNTER_COUNT; i++) {
        csr_write_imm(CSR_MPERFSEL, TOMASULO_PROFILE_LEGACY_COUNTER_COUNT + i);
        cache_counters[i] = tomasulo_profile_read_selected_counter64();
    }
}

CACHE_PROFILE_TEXT void tomasulo_profile_read_cache_pair(tomasulo_profile_snapshot_t *start,
                                                         tomasulo_profile_snapshot_t *end)
{
    uint64_t *start_cache = (uint64_t *) (uintptr_t) start->cache_counters_addr;
    uint64_t *end_cache = (uint64_t *) (uintptr_t) end->cache_counters_addr;

    if (start_cache != NULL && end_cache != NULL) {
        read_cache_bank(end_cache, 0U);
        read_cache_bank(start_cache, 2U);
    }
    csr_write_imm(CSR_MPERFCTL, 0U);
}

static CACHE_PROFILE_TEXT void print_metric(const char *label, uint64_t value, uint64_t total)
{
    uint32_t pct_x10 = tomasulo_profile_pct_x10(value, total);
    uart_printf(metric_prefix, label);
    uart_printf(u64_hex_format, (unsigned int) (value >> 32), (unsigned int) (value & 0xFFFFFFFFu));
    uart_printf(metric_suffix, (unsigned long) (pct_x10 / 10U), (unsigned long) (pct_x10 % 10U));
}

static CACHE_PROFILE_TEXT void print_hit_rate(const char *label, uint64_t hits, uint64_t accesses)
{
    if (accesses == 0U) {
        uart_printf(no_accesses, label);
    } else {
        uint32_t hit_rate_x10 = tomasulo_profile_ratio_scaled(hits, accesses, 1000U);
        uart_printf(hit_rate,
                    label,
                    (unsigned long) (hit_rate_x10 / 10U),
                    (unsigned long) (hit_rate_x10 % 10U));
    }
}

static CACHE_PROFILE_TEXT void
print_miss_latency(const char *label, uint64_t miss_cycles_sum, uint64_t misses)
{
    if (misses == 0U) {
        uart_printf(no_misses, label);
    } else {
        uint32_t latency_x100 = tomasulo_profile_ratio_scaled(miss_cycles_sum, misses, 100U);
        uart_printf(miss_latency,
                    label,
                    (unsigned long) (latency_x100 / 100U),
                    (unsigned long) (latency_x100 % 100U));
    }
}

static CACHE_PROFILE_TEXT __attribute__((noinline)) void
print_cache_report_and_diagnostic_header(const tomasulo_profile_snapshot_t *start,
                                         const tomasulo_profile_snapshot_t *end,
                                         const char *report_diagnostic_header)
{
    uint64_t start_local[TOMASULO_PROFILE_CACHE_COUNTER_COUNT];
    uint64_t end_local[TOMASULO_PROFILE_CACHE_COUNTER_COUNT];
    const uint64_t *start_cache = (const uint64_t *) (uintptr_t) start->cache_counters_addr;
    const uint64_t *end_cache = (const uint64_t *) (uintptr_t) end->cache_counters_addr;
    uint64_t cycles = end->cycles - start->cycles;
    uint64_t l1i_access;
    uint64_t l1i_hit;
    uint64_t l1i_miss;
    uint64_t l1i_writeback;
    uint64_t l1d_access;
    uint64_t l1d_hit;
    uint64_t l1d_miss;
    uint64_t l1d_writeback;
    uint64_t l2_access;
    uint64_t l2_hit;
    uint64_t l2_miss;
    uint64_t l2_writeback;
    uint64_t l1i_fetch_miss_stall;
    uint64_t l1d_miss_cycles;
    uint64_t l2_miss_cycles;
    uint64_t l1i_hum;
    uint64_t l1d_hum;
    uint64_t l2_hum;
    uint64_t l1d_full_stall;
    uint64_t l2_full_stall;
    uint64_t l1d_conflict_stall;
    uint64_t l2_conflict_stall;
    uint64_t l1d_overlap;
    uint64_t l2_overlap;

    /*
     * Full-report users may omit sidecars. Drain into post-timing stack
     * storage in that case; otherwise reuse the pair already drained by the
     * caller. No further snapshot may occur between the end capture and here.
     */
    if (start_cache == NULL || end_cache == NULL) {
        read_cache_bank(end_local, 0U);
        read_cache_bank(start_local, 2U);
        csr_write_imm(CSR_MPERFCTL, 0U);
        start_cache = start_local;
        end_cache = end_local;
    }

#define CACHE_DELTA(index) (end_cache[(index)] - start_cache[(index)])
    l1i_access = CACHE_DELTA(0);
    l1i_hit = CACHE_DELTA(1);
    l1i_miss = CACHE_DELTA(2);
    l1i_writeback = CACHE_DELTA(3);
    l1d_access = CACHE_DELTA(4);
    l1d_hit = CACHE_DELTA(5);
    l1d_miss = CACHE_DELTA(6);
    l1d_writeback = CACHE_DELTA(7);
    l2_access = CACHE_DELTA(8);
    l2_hit = CACHE_DELTA(9);
    l2_miss = CACHE_DELTA(10);
    l2_writeback = CACHE_DELTA(11);
    l1i_fetch_miss_stall = CACHE_DELTA(12);
    l1d_miss_cycles = CACHE_DELTA(13);
    l2_miss_cycles = CACHE_DELTA(14);
    l1i_hum = CACHE_DELTA(15);
    l1d_hum = CACHE_DELTA(16);
    l2_hum = CACHE_DELTA(17);
    l1d_full_stall = CACHE_DELTA(18);
    l2_full_stall = CACHE_DELTA(19);
    l1d_conflict_stall = CACHE_DELTA(20);
    l2_conflict_stall = CACHE_DELTA(21);
    l1d_overlap = CACHE_DELTA(22);
    l2_overlap = CACHE_DELTA(23);
#undef CACHE_DELTA

    uart_printf(cache_header);
    print_metric(l1i_access_label, l1i_access, cycles);
    print_metric(l1i_hit_label, l1i_hit, l1i_access);
    print_metric(l1i_miss_label, l1i_miss, l1i_access);
    print_metric(l1i_writeback_label, l1i_writeback, l1i_access);
    print_hit_rate(l1i, l1i_hit, l1i_access);

    print_metric(l1d_access_label, l1d_access, cycles);
    print_metric(l1d_hit_label, l1d_hit, l1d_access);
    print_metric(l1d_miss_label, l1d_miss, l1d_access);
    print_metric(l1d_writeback_label, l1d_writeback, l1d_access);
    print_hit_rate(l1d, l1d_hit, l1d_access);

    print_metric(l2_access_label, l2_access, cycles);
    print_metric(l2_hit_label, l2_hit, l2_access);
    print_metric(l2_miss_label, l2_miss, l2_access);
    print_metric(l2_writeback_label, l2_writeback, l2_access);
    print_hit_rate(l2, l2_hit, l2_access);

    print_metric(l1i_stall_label, l1i_fetch_miss_stall, cycles);
    print_miss_latency(l1d, l1d_miss_cycles, l1d_miss);
    print_miss_latency(l2, l2_miss_cycles, l2_miss);
    print_metric(l1i_hum_label, l1i_hum, l1i_hit);
    print_metric(l1d_hum_label, l1d_hum, l1d_hit);
    print_metric(l2_hum_label, l2_hum, l2_hit);
    print_metric(l1d_full_label, l1d_full_stall, cycles);
    print_metric(l2_full_label, l2_full_stall, cycles);
    print_metric(l1d_conflict_label, l1d_conflict_stall, cycles);
    print_metric(l2_conflict_label, l2_conflict_stall, cycles);
    print_metric(l1d_overlap_label, l1d_overlap, cycles);
    print_metric(l2_overlap_label, l2_overlap, cycles);
    uart_printf(report_diagnostic_header);
}

CACHE_PROFILE_TEXT void
tomasulo_profile_print_cache_report_and_diagnostic_header(const tomasulo_profile_snapshot_t *start,
                                                          const tomasulo_profile_snapshot_t *end)
{
    print_cache_report_and_diagnostic_header(start, end, diagnostic_header);
}

CACHE_PROFILE_TEXT void
tomasulo_profile_print_default_cache_report_and_diagnostic_header(const char *report_header)
{
    print_cache_report_and_diagnostic_header(&tomasulo_profile_default_report_start,
                                             &tomasulo_profile_default_report_end,
                                             report_header);
}
