/*
 *    Copyright (c) 2026 John Goodacre.
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
 * Slab-like reuse of 256-byte nodes, as the kernel's maple tree reuses them in
 * fork: an allocation reads the free pointer at +0x80, zeroes the node with a
 * memset (four full 64-byte lines), copies a parent node into it with
 * memcpy's load-then-store groups, and reads it back; a free writes a new free
 * pointer. cbo.zero (clear_page), node rewrites and partial stores mix in. The
 * nodes lie 512 KiB apart, so every node maps onto the same L1D and L2 sets
 * and the lines are evicted and refilled between uses. A shadow copy in other
 * sets models every byte; every load is checked against it.
 */
#include <stdint.h>

#include "uart.h"

#define NODES 16u
#define NODE_BYTES 256u
#define NODE_BASE 0x82000000ul
#define NODE_STRIDE 0x80000ul
#define SHADOW_BASE 0x81400000ul
#ifndef NODE_OPS
#define NODE_OPS 2500u
#endif

#define CBO_ZERO(p) __asm__ volatile(".insn i 0x0F, 2, x0, %0, 4" ::"r"(p) : "memory")

static uint32_t g_failures;
static uint64_t g_rng;

static uint64_t rnd(void)
{
    g_rng ^= g_rng << 13;
    g_rng ^= g_rng >> 7;
    g_rng ^= g_rng << 17;
    return g_rng;
}

static volatile uint64_t *node(uint32_t n)
{
    return (volatile uint64_t *) (NODE_BASE + NODE_STRIDE * n);
}

static volatile uint64_t *shadow(uint32_t n)
{
    return (volatile uint64_t *) (SHADOW_BASE + NODE_BYTES * n);
}

static void fail(const char *what, uint32_t n, uint32_t word, uint64_t got, uint64_t want)
{
    if (g_failures < 16)
        uart_printf("FAIL %s node %u +%x got=%lx want=%lx\n", what, n, word * 8, got, want);
    g_failures++;
}

static void check_word(const char *what, uint32_t n, uint32_t word)
{
    uint64_t got = node(n)[word];
    uint64_t want = shadow(n)[word];
    if (got != want)
        fail(what, n, word, got, want);
}

/* memset(p, 0, 256): eight dword stores per 64-byte line. */
static void zero_node(volatile uint64_t *p)
{
    for (uint32_t i = 0; i < NODE_BYTES / 8; i += 8) {
        p[i + 0] = 0;
        p[i + 1] = 0;
        p[i + 2] = 0;
        p[i + 3] = 0;
        p[i + 4] = 0;
        p[i + 5] = 0;
        p[i + 6] = 0;
        p[i + 7] = 0;
    }
}

/* memcpy(d, s, 256): groups of loads, then their stores. */
static void copy_node(volatile uint64_t *d, volatile uint64_t *s, uint32_t group)
{
    for (uint32_t i = 0; i < NODE_BYTES / 8; i += 8) {
        uint64_t a = s[i + 0], b = s[i + 1], c = s[i + 2], e = s[i + 3];
        if (group == 4) {
            d[i + 0] = a;
            d[i + 1] = b;
            d[i + 2] = c;
            d[i + 3] = e;
        }
        uint64_t f = s[i + 4], g = s[i + 5], h = s[i + 6], k = s[i + 7];
        if (group != 4) {
            d[i + 0] = a;
            d[i + 1] = b;
            d[i + 2] = c;
            d[i + 3] = e;
        }
        d[i + 4] = f;
        d[i + 5] = g;
        d[i + 6] = h;
        d[i + 7] = k;
    }
}

static void op_pop_copy(uint32_t dst, uint32_t src)
{
    /* The allocator reads the free pointer at +0x80. */
    check_word("freeptr", dst, 0x80 / 8);
    zero_node(node(dst));
    zero_node(shadow(dst));
    uint32_t group = (uint32_t) (rnd() & 1) ? 4u : 8u;
    copy_node(node(dst), node(src), group);
    copy_node(shadow(dst), shadow(src), group);
    uint32_t reads = (uint32_t) (rnd() % 12);
    for (uint32_t i = 0; i < reads; i++)
        check_word("pop", dst, (uint32_t) (rnd() % (NODE_BYTES / 8)));
}

static void op_free(uint32_t n)
{
    uint64_t v = rnd();
    node(n)[0x80 / 8] = v;
    shadow(n)[0x80 / 8] = v;
}

static void op_rewrite(uint32_t n)
{
    for (uint32_t i = 0; i < NODE_BYTES / 8; i++) {
        uint64_t v = rnd();
        node(n)[i] = v;
        shadow(n)[i] = v;
    }
}

static void op_cbo_zero(uint32_t n)
{
    uint64_t pick = rnd();
    for (uint32_t b = 0; b < NODE_BYTES / 64; b++) {
        if (!((pick >> b) & 1))
            continue;
        CBO_ZERO((uint64_t) node(n) + 64 * b);
        CBO_ZERO((uint64_t) shadow(n) + 64 * b);
    }
    for (uint32_t i = 0; i < (uint32_t) (rnd() % 4); i++) {
        uint32_t w = (uint32_t) (rnd() % (NODE_BYTES / 8));
        uint64_t v = rnd();
        node(n)[w] = v;
        shadow(n)[w] = v;
    }
}

static void op_partial(uint32_t n)
{
    uint32_t count = 1 + (uint32_t) (rnd() % 8);
    for (uint32_t i = 0; i < count; i++) {
        uint64_t r = rnd();
        uint32_t off = (uint32_t) (r % NODE_BYTES);
        uint64_t v = r >> 17;
        switch ((r >> 40) % 3) {
            case 0:
                ((volatile uint8_t *) node(n))[off] = (uint8_t) v;
                ((volatile uint8_t *) shadow(n))[off] = (uint8_t) v;
                break;
            case 1:
                off &= ~3u;
                ((volatile uint32_t *) node(n))[off / 4] = (uint32_t) v;
                ((volatile uint32_t *) shadow(n))[off / 4] = (uint32_t) v;
                break;
            default:
                off &= ~7u;
                node(n)[off / 8] = v;
                shadow(n)[off / 8] = v;
                break;
        }
    }
}

int main(void)
{
    g_failures = 0;
    g_rng = 0x243F6A8885A308D3ull;
    for (uint32_t n = 0; n < NODES; n++) {
        for (uint32_t i = 0; i < NODE_BYTES / 8; i++) {
            uint64_t v = rnd();
            node(n)[i] = v;
            shadow(n)[i] = v;
        }
    }
    for (uint32_t op = 0; op < NODE_OPS; op++) {
        uint64_t r = rnd();
        uint32_t dst = (uint32_t) (r % NODES);
        uint32_t src = (dst + 1 + (uint32_t) ((r >> 8) % (NODES - 1))) % NODES;
        uint32_t kind = (uint32_t) ((r >> 16) % 20);
        if (kind < 7)
            op_pop_copy(dst, src);
        else if (kind < 9)
            op_free(dst);
        else if (kind < 11)
            op_rewrite(dst);
        else if (kind < 13)
            op_cbo_zero(dst);
        else if (kind < 16)
            op_partial(dst);
        else
            for (uint32_t i = 0; i < 8; i++)
                check_word(
                    "load", (uint32_t) (rnd() % NODES), (uint32_t) (rnd() % (NODE_BYTES / 8)));
        if ((op & 255) == 255)
            uart_printf("ops %u failures %u\n", op + 1, g_failures);
    }
    for (uint32_t n = 0; n < NODES; n++)
        for (uint32_t i = 0; i < NODE_BYTES / 8; i++)
            check_word("final", n, i);
    uart_printf("node_reuse failures %u\n", g_failures);
    uart_puts(g_failures ? "<<FAIL>>\n" : "<<PASS>>\n");
    for (;;) {
    }
    return 0;
}
