// Copyright (c) 2026 John Goodacre.

/*
 * l2_capacity_chase: dependent-load latency over working sets around the L2
 * capacity. Each working set is a random cycle through its 64-byte lines, one
 * pointer per line. A checked walk warms it, a second walk is timed: a set that fits
 * the L2 shows the L2-hit latency per hop, a larger one the DDR latency.
 *
 * Sizes (KiB) come from L2CC_SIZES_KIB (default 1024, 3072, 4096, 5120); the L2
 * capacity of the build under test only moves where the step falls.
 */
#include "csr.h"
#include "uart.h"
#include <stdint.h>

#define LINE 64u
#define MIB (1u << 20)
#define DDR_BASE 0x80000000u
#define WS_BASE (DDR_BASE + 16u * MIB)
#define PERM_BASE (DDR_BASE + 32u * MIB)

#ifndef L2CC_SIZES_KIB
#define L2CC_SIZES_KIB 1024u, 3072u, 4096u, 5120u
#endif

static uint32_t rng_state = 0x2545f491u;

static int working_set_lines(uint32_t kib, uint32_t *lines)
{
    uint64_t bytes = (uint64_t) kib * 1024u;
    if (bytes == 0 || bytes > PERM_BASE - WS_BASE)
        return 0;
    *lines = (uint32_t) (bytes / LINE);
    return 1;
}

static inline uint32_t rng(void)
{
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

/* Link the lines of the working set into one random cycle (Sattolo). */
static void build_cycle(volatile uint64_t *ws, volatile uint32_t *perm, uint32_t lines)
{
    for (uint32_t i = 0; i < lines; i++)
        perm[i] = i;
    for (uint32_t i = lines - 1u; i > 0u; i--) {
        uint32_t j = rng() % i;
        uint32_t t = perm[i];
        perm[i] = perm[j];
        perm[j] = t;
    }
    for (uint32_t i = 0; i < lines; i++) {
        uint32_t from = perm[i];
        uint32_t to = perm[(i + 1u == lines) ? 0u : i + 1u];
        ws[(uint64_t) from * (LINE / 8u)] = (uint64_t) (uintptr_t) &ws[(uint64_t) to * (LINE / 8u)];
    }
}

__attribute__((noipa)) static uint64_t walk(uint64_t p, uint32_t hops)
{
    for (uint32_t i = 0; i < hops; i++)
        p = *(volatile uint64_t *) (uintptr_t) p;
    return p;
}

/* Check each pointer before dereferencing it, and require the first return
 * to the start after exactly one visit to every line. This also warms the
 * complete working set without accepting a short cycle. */
static int validate_cycle(uint64_t start, uint32_t lines)
{
    uint64_t p = start;
    uint64_t bytes = (uint64_t) lines * LINE;
    for (uint32_t i = 0; i < lines; i++) {
        if (p < start || p - start >= bytes || (p - start) % LINE != 0)
            return 0;
        p = *(volatile uint64_t *) (uintptr_t) p;
        if (p == start && i + 1u != lines)
            return 0;
    }
    return lines != 0 && p == start;
}

int main(void)
{
    static const uint32_t sizes_kib[] = {L2CC_SIZES_KIB};
    uint32_t failures = 0;

    uart_printf("l2_capacity_chase\n");
    for (unsigned s = 0; s < sizeof(sizes_kib) / sizeof(sizes_kib[0]); s++) {
        uint32_t lines;
        if (!working_set_lines(sizes_kib[s], &lines)) {
            uart_printf("ERROR: working set must be 1 to 16384 KiB\n");
            failures++;
            continue;
        }
        volatile uint64_t *ws = (volatile uint64_t *) WS_BASE;
        build_cycle(ws, (volatile uint32_t *) PERM_BASE, lines);
        uint64_t start_p = (uint64_t) (uintptr_t) ws;
        if (!validate_cycle(start_p, lines)) {
            uart_printf("ERROR: invalid working-set cycle\n");
            failures++;
            continue;
        }
        uint64_t t0 = rdcycle64();
        uint64_t p = walk(start_p, lines); /* timed: one full cycle */
        uint64_t cycles = rdcycle64() - t0;
        if (p != start_p) {
            uart_printf("ERROR: the walk did not close its cycle\n");
            failures++;
        }
        uart_printf("L2CC kib=%lu lines=%lu cycles=%lu cyc_per_hop_x100=%lu\n",
                    (unsigned long) sizes_kib[s],
                    (unsigned long) lines,
                    (unsigned long) cycles,
                    (unsigned long) (cycles * 100u / lines));
    }
    uart_printf(failures == 0 ? "<<PASS>>\n" : "<<FAIL>>\n");
    return (int) failures;
}
