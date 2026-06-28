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
 * Hardened self-modifying-code / fence.i directed reproducer.
 *
 * Models the kernel's runtime code-patching contract (patch_insn_write +
 * fence.i): store a new instruction word into cached-DDR code, fence.i to
 * sync, then fetch/execute it. The fence.i must:
 *   store -> SQ -> L1D (dirty) ... new code invisible to fetch
 *   fence.i: drain committed SQ -> L1D writeback-all -> L1I invalidate-all
 *            -> fetch-buffer invalidate
 *   call -> L1I miss -> fill returns the freshly written code
 *
 * The gentle ddr_smc_test passes; this sweeps the timing/layout knobs that the
 * boot hang implicates so a transient becomes a deterministic, waveform-able
 * failure:
 *   - store->fence.i freshness GAP (0/1/2/3/4/8 nops): how fresh the committed
 *     store is when fence.i drains the store queue.
 *   - WARM L1D (write-hit) vs COLD L1D (write-allocate miss): the L1D is
 *     128 KiB direct-mapped with 32 B lines, so a single read +128 KiB shares
 *     the index but not the tag and conflict-evicts the ddr_code line, forcing
 *     the next patch store to miss and race the fence.i writeback walk.
 *   - tight alternating self-modify loops (a stale/previous read is always a
 *     detectable mismatch).
 *
 * Prints "<<PASS>>" if every post-fence.i call returns its freshly written
 * value; "<<FAIL>>" with detail otherwise. A wedge (stale garbage executed)
 * shows up as a simulation/UART timeout.
 */

#include <stdint.h>

#include "../../lib/include/uart.h"

#define ADDI_A0(imm) (0x00000513u | (((uint32_t) (imm) & 0xfffu) << 20)) /* addi a0,x0,imm */
#define RET_INSN 0x00008067u                                             /* jalr x0,0(ra)  */

/* Executable + writable patch target in the cached DDR region, line aligned
 * (LINE_BYTES = 32). ddr_code[0] is the entry (patched); [1] is `ret`. */
__attribute__((section(".ddr_data"), aligned(32))) static volatile uint32_t ddr_code[8];

/* Direct-mapped L1D = 128 KiB. */
#define L1D_BYTES (128u * 1024u)

typedef int (*fn_t)(void);

/* Patch word[0] with `addi a0,x0,imm`, then GAP nops, then fence.i. The single
 * 32-bit store mirrors patch_insn_write; GAP varies how fresh the committed
 * store is when the fence.i serializer drains the SQ. */
#define MK_PATCH(name, nops)                                                                       \
    static inline void name(uint32_t imm)                                                          \
    {                                                                                              \
        __asm__ volatile("sw %1, 0(%0)\n\t" nops "fence.i\n\t"                                     \
                         :                                                                         \
                         : "r"(&ddr_code[0]), "r"(ADDI_A0(imm))                                    \
                         : "memory");                                                              \
    }
MK_PATCH(patch_g0, "")
MK_PATCH(patch_g1, "nop\n\t")
MK_PATCH(patch_g2, "nop\n\tnop\n\t")
MK_PATCH(patch_g3, "nop\n\tnop\n\tnop\n\t")
MK_PATCH(patch_g4, "nop\n\tnop\n\tnop\n\tnop\n\t")
MK_PATCH(patch_g8, "nop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\t")

typedef void (*patch_fn_t)(uint32_t);
static patch_fn_t const patchers[] = {patch_g0, patch_g1, patch_g2, patch_g3, patch_g4, patch_g8};
static const int gaps[] = {0, 1, 2, 3, 4, 8};
#define NGAPS ((int) (sizeof(gaps) / sizeof(gaps[0])))

/* Conflict-evict the ddr_code line from a direct-mapped L1D (read several
 * +N*128 KiB aliases; one suffices for direct-mapped, extras cover any
 * set-assoc surprise). */
static inline void evict_code_line(void)
{
    uintptr_t base = (uintptr_t) &ddr_code[0];
    volatile uint32_t *a1 = (volatile uint32_t *) (base + 1u * L1D_BYTES);
    volatile uint32_t *a2 = (volatile uint32_t *) (base + 2u * L1D_BYTES);
    volatile uint32_t *a3 = (volatile uint32_t *) (base + 3u * L1D_BYTES);
    volatile uint32_t *a4 = (volatile uint32_t *) (base + 4u * L1D_BYTES);
    volatile uint32_t s = *a1 + *a2 + *a3 + *a4;
    (void) s;
}

static int g_fail;
static int g_reported;

static void check(int tag, int gap, uint32_t want, int cold)
{
    fn_t fn = (fn_t) (uintptr_t) &ddr_code[0];
    int got = fn();
    if (got != (int) want) {
        g_fail++;
        if (g_reported < 16) {
            uart_printf("FAIL tag=%x gap=%d cold=%d got=0x%x want=0x%x\n",
                        (unsigned) tag,
                        gap,
                        cold,
                        (unsigned) got,
                        (unsigned) want);
            g_reported++;
        }
    }
}

int main(void)
{
    /* Establish word[1] = ret once and sync it in. */
    ddr_code[1] = RET_INSN;
    __asm__ volatile("fence.i" ::: "memory");

    /* Phase A: gap sweep, WARM L1D (write-hit). */
    uart_printf("A");
    for (int rep = 0; rep < 4; rep++) {
        for (int g = 0; g < NGAPS; g++) {
            uint32_t want = ((rep + g) & 1) ? 0x2Au : 0x355u;
            patchers[g](want);
            check(0xA, gaps[g], want, 0);
        }
    }

    /* Phase B: gap sweep, COLD L1D (write-allocate miss). */
    uart_printf("B");
    for (int rep = 0; rep < 4; rep++) {
        for (int g = 0; g < NGAPS; g++) {
            uint32_t want = ((rep + g) & 1) ? 0x111u : 0x222u;
            evict_code_line();
            patchers[g](want);
            check(0xB, gaps[g], want, 1);
        }
    }

    /* Phase C: tight alternating self-modify loop, gap 0, warm. */
    uart_printf("C");
    for (int i = 0; i < 96; i++) {
        uint32_t want = (i & 1) ? 0x123u : 0x456u;
        patch_g0(want);
        check(0xC, 0, want, 0);
    }

    /* Phase D: tight alternating self-modify loop, gap 0, cold (miss each time). */
    uart_printf("D");
    for (int i = 0; i < 48; i++) {
        uint32_t want = (i & 1) ? 0x0AAu : 0x055u;
        evict_code_line();
        patch_g0(want);
        check(0xD, 0, want, 1);
    }

    if (g_fail == 0) {
        uart_printf("\n<<PASS>>\n");
    } else {
        uart_printf("\n<<FAIL>> (%d failures)\n", g_fail);
    }

    for (;;) {
    }
    return 0;
}
