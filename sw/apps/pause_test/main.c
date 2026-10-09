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
 * PAUSE decode test. Zihintpause encodes PAUSE as 0x0100000F: FENCE with
 * fm=0, pred=W, succ=0 and rd=rs1=x0. FROST treats it as a NOP, without a
 * committed-store drain. Other FENCE encodings, including fence r,0
 * (0x0200000F), must still wait for committed stores.
 *
 * Check the assembler encoding, drain behavior and retirement. The drain
 * check needs PERF_COUNTERS=1 and reports SKIP if counters are absent.
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

/* COMMIT_BLOCKED_FENCE cycles over STORES_PER_LOOP stores, each followed by
 * the instruction `insn` (assembler text), stored in `out`. */
#define BLOCKED_AFTER_STORES_THEN(insn, out)                                                       \
    do {                                                                                           \
        uint64_t before_ = fence_blocked_cycles();                                                 \
        __asm__ volatile(".rept %2\n"                                                              \
                         "sd %1, 0(%0)\n" insn "\n"                                                \
                         ".endr\n"                                                                 \
                         :                                                                         \
                         : "r"(&g_store_slot), "r"(0x5A5Aul), "i"(STORES_PER_LOOP)                 \
                         : "memory");                                                              \
        (out) = fence_blocked_cycles() - before_;                                                  \
    } while (0)

/* FENCE must wait for the stores to drain; PAUSE must not. */
static void report_drain(const char *insn, uint64_t blocked, int drains)
{
    int ok = drains ? blocked != 0 : blocked == 0;
    if (!ok)
        g_ok = 0;
    uart_printf("%s B %s %s stores (fence-blocked cycles: %u)\n",
                ok ? "[PASS]" : "[FAIL]",
                insn,
                drains ? "drains" : "does not drain",
                (uint32_t) blocked);
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

    /* B: PAUSE never waits for committed stores to drain; the FENCE words
     * do. fence w,w comes from the mnemonic, the rest are C's words. */
    if (csr_read_imm(CSR_MPERFCOUNT) <= TOMASULO_PERF_COMMIT_BLOCKED_FENCE) {
        uart_printf("[SKIP] B needs the profiling counters (PERF_COUNTERS=1)\n");
    } else {
        uint64_t blocked;
        BLOCKED_AFTER_STORES_THEN(".word 0x0100000F", blocked);
        report_drain("pause", blocked, 0);
        BLOCKED_AFTER_STORES_THEN("fence w, w", blocked);
        report_drain("fence w,w", blocked, 1);
        BLOCKED_AFTER_STORES_THEN(".word 0x0200000F", blocked);
        report_drain("fence r,0", blocked, 1);
        BLOCKED_AFTER_STORES_THEN(".word 0x0000000F", blocked);
        report_drain("fence 0,0", blocked, 1);
        BLOCKED_AFTER_STORES_THEN(".word 0x0330000F", blocked);
        report_drain("fence rw,rw", blocked, 1);
        BLOCKED_AFTER_STORES_THEN(".word 0x8330000F", blocked);
        report_drain("fence.tso", blocked, 1);
        BLOCKED_AFTER_STORES_THEN(".word 0x0100008F", blocked);
        report_drain("pred=W succ=0 rd=x1", blocked, 1);
        BLOCKED_AFTER_STORES_THEN(".word 0x0100800F", blocked);
        report_drain("pred=W succ=0 rs1=x1", blocked, 1);
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
