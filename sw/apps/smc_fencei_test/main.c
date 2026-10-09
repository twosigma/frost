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
 * Self-modifying code with fence.i.
 *
 * Model patch_insn_write followed by fence.i: patch a cached-DDR instruction,
 * synchronize it, then execute it. Required ordering:
 *   store -> SQ -> L1D (dirty) ... new code invisible to fetch
 *   fence.i: drain committed SQ -> L1D writeback-all -> L1I invalidate-all
 *            -> fetch-buffer invalidate
 *   call -> L1I miss -> fill returns the freshly written code
 *
 * Sweep the store-to-fence.i gap and use warm and cold cache lines. A cold
 * patch store needs write allocation before fence.i can write it back.
 * Alternate return values so executing stale code produces a mismatch.
 */

#include <stdint.h>

#include "../../lib/include/uart.h"

#define ADDI_A0(imm) (0x00000513u | (((uint32_t) (imm) & 0xfffu) << 20)) /* addi a0,x0,imm */
#define RET_INSN 0x00008067u                                             /* jalr x0,0(ra)  */

/* Executable + writable patch target in the cached DDR region, aligned to a
 * 32-byte cache line. ddr_code[0] is the entry (patched); [1] is `ret`. */
__attribute__((section(".ddr_data"), aligned(32))) static volatile uint32_t ddr_code[8];
/* PCREL_HI20 cannot reach DDR from low BRAM on LP64. Keep the address in a
 * data relocation; volatile prevents -O3 from folding it back. */
static volatile uint32_t *volatile ddr_code_p = &ddr_code[0];

/* Direct-mapped L1D = 128 KiB. */
#define L1D_BYTES (128u * 1024u)

typedef int (*fn_t)(void);

/* Store a 32-bit patch_insn_write-style instruction, wait the chosen NOP
 * gap, then fence.i. Vary the store's age when the serializer drains it. */
#define MK_PATCH(name, nops)                                                                       \
    static inline void name(uint32_t imm)                                                          \
    {                                                                                              \
        __asm__ volatile("sw %1, 0(%0)\n\t" nops "fence.i\n\t"                                     \
                         :                                                                         \
                         : "r"(ddr_code_p), "r"(ADDI_A0(imm))                                      \
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

/* Conflict-evict the ddr_code line by reading aliases at +N*128 KiB. One read
 * is enough for the direct-mapped L1D; the extra reads also cover a
 * set-associative L1D. */
static inline void evict_code_line(void)
{
    uintptr_t base = (uintptr_t) ddr_code_p;
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
    fn_t fn = (fn_t) (uintptr_t) ddr_code_p;
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
    ddr_code_p[1] = RET_INSN;
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
