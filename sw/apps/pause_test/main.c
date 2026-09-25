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
 * PAUSE decode directed test.
 *
 * PAUSE (Zihintpause) is the FENCE encoding with fm=0, pred=W, succ=0 and
 * rd=rs1=x0, exactly 0x0100000F. FROST runs it as a NOP, so it must retire
 * without the committed-store drain that a FENCE waits for at the ROB head.
 * Every other FENCE encoding, fence r,0 (0x0200000F) included, must retire as
 * a FENCE. Self-checks over UART (<<PASS>>/<<FAIL>>):
 *
 *   A. The assembler's `pause` is 0x0100000F.
 *   B. Stores each followed by PAUSE add nothing to the COMMIT_BLOCKED_FENCE
 *      profiling counter; the same stores each followed by fence w,w do,
 *      which shows that the counter sees the drain. Needs the profiling
 *      counters (PERF_COUNTERS=1, as the cocotb entry builds); without them
 *      the check reports SKIP.
 *   C. PAUSE, the FENCE encodings that differ from it in one field, fence
 *      rw,rw and fence.tso retire, and execution continues past each. An
 *      instruction that never retires keeps the run from reaching <<PASS>>.
 */

#include <stdint.h>

#include "tomasulo_profile.h"

#define PAUSE_WORD 0x0100000Fu
#define STORES_PER_LOOP 16

static int g_ok = 1;
static volatile uint64_t g_store_slot;

static void report(const char *name, int ok)
{
    if (!ok)
        g_ok = 0;
    uart_printf("%s %s\n", ok ? "[PASS]" : "[FAIL]", name);
}

/* COMMIT_BLOCKED_FENCE from a fresh snapshot of the profiling counters. */
static uint64_t fence_blocked_cycles(void)
{
    csr_write_imm(CSR_MPERFCTL, 1U);
    csr_write_imm(CSR_MPERFSEL, TOMASULO_PERF_COMMIT_BLOCKED_FENCE);
    return tomasulo_profile_read_selected_counter64();
}

static void stores_then_pause(volatile uint64_t *slot)
{
    __asm__ volatile(".rept %2\n"
                     "sd %1, 0(%0)\n"
                     ".word 0x0100000F\n" /* pause */
                     ".endr\n"
                     :
                     : "r"(slot), "r"(0x5A5Aul), "i"(STORES_PER_LOOP)
                     : "memory");
}

static void stores_then_fence(volatile uint64_t *slot)
{
    __asm__ volatile(".rept %2\n"
                     "sd %1, 0(%0)\n"
                     "fence w, w\n"
                     ".endr\n"
                     :
                     : "r"(slot), "r"(0xA5A5ul), "i"(STORES_PER_LOOP)
                     : "memory");
}

int main(void)
{
    uart_printf("\n=== PAUSE decode test ===\n");

    /* A: the toolchain's encoding of the mnemonic. The word may sit at a
     * halfword address, so read it as two halfwords. */
    uint32_t encoded;
    __asm__ volatile("la   t0, 1f\n"
                     "lhu  %0, 0(t0)\n"
                     "lhu  t1, 2(t0)\n"
                     "slli t1, t1, 16\n"
                     "or   %0, %0, t1\n"
                     "j    2f\n"
                     "1:\n"
                     "pause\n"
                     "2:\n"
                     : "=&r"(encoded)
                     :
                     : "t0", "t1", "memory");
    uart_printf("pause encodes as %08x\n", encoded);
    report("A pause mnemonic is 0x0100000F", encoded == PAUSE_WORD);

    /* B: PAUSE never waits for committed stores to drain. */
    if (csr_read_imm(CSR_MPERFCOUNT) <= TOMASULO_PERF_COMMIT_BLOCKED_FENCE) {
        uart_printf("[SKIP] B needs the profiling counters (PERF_COUNTERS=1)\n");
    } else {
        uint64_t start = fence_blocked_cycles();
        stores_then_pause(&g_store_slot);
        uint64_t after_pause = fence_blocked_cycles();
        stores_then_fence(&g_store_slot);
        uint64_t after_fence = fence_blocked_cycles();
        uint64_t pause_blocked = after_pause - start;
        uint64_t fence_blocked = after_fence - after_pause;
        uart_printf("fence-blocked cycles: %u after pause, %u after fence w,w\n",
                    (uint32_t) pause_blocked,
                    (uint32_t) fence_blocked);
        report("B pause does not drain stores", pause_blocked == 0);
        report("B fence w,w drains stores", fence_blocked != 0);
    }

    /* C: each word retires. fence r,0 differs from PAUSE only in pred. */
    __asm__ volatile(".word 0x0100000F\n" /* pause */
                     ".word 0x0200000F\n" /* fence r,0 */
                     ".word 0x0000000F\n" /* fence 0,0 */
                     ".word 0x0330000F\n" /* fence rw,rw */
                     ".word 0x8330000F\n" /* fence.tso */
                     ".word 0x0100008F\n" /* pred=W, succ=0, rd=x1 */
                     ".word 0x0100800F\n" /* pred=W, succ=0, rs1=x1 */
                     "pause\n" ::
                         : "memory");
    report("C pause and the FENCE encodings retire", 1);

    uart_printf(g_ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
    return 0;
}
