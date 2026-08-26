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
 * Committed-store drain across the D10 translation flush.
 *
 * A store committed immediately before a translation-relevant CSR write must
 * survive the post-commit full flush: the flush resets the store queue, so
 * without the reorder buffer's drain gate a committed-but-undrained cached
 * store is lost architecturally. That is page-table setup's exact shape
 * (sd PTE; csrw satp) — the env_v demand pager lost its UART megapage PTE
 * this way and livelocked. The repro needs the store still in flight when
 * the CSR commits, so every iteration stores to cached DDR (slow drain) and
 * writes the CSR in the very next instructions.
 *
 * Case 1: sd to cached DDR; csrw satp (Bare->Bare rewrites still flush per
 *         D10); ld back and compare.
 * Case 2: the same with an mstatus.SUM value toggle (the mstatus flavor of
 *         the D10 flush), restoring mstatus afterwards (a second flush).
 */

#include <stdint.h>

#include "csr.h"
#include "uart.h"

#define N 64

volatile uint64_t ddr_slots[N] __attribute__((section(".ddr_data"), aligned(64)));

int main(void)
{
    int fail = 0;

    /* TWO back-to-back stores per iteration: the cached tier drains one
     * store at a time, so the second sits committed-but-undrained when the
     * CSR's post-commit flush fires — the store the unfixed flush lost
     * (adjacent dwords of one line, the page-table-setup shape). */
    for (int i = 0; i < N / 2; i++) {
        ddr_slots[2 * i] = 0xA5A5000000000000ULL + (uint64_t) (2 * i);
        ddr_slots[2 * i + 1] = 0xA5A5000000000000ULL + (uint64_t) (2 * i + 1);
        csr_write(satp, 0); /* Bare->Bare: still a D10 flush */
        for (int k = 2 * i; k <= 2 * i + 1; k++) {
            uint64_t got = ddr_slots[k];
            if (got != 0xA5A5000000000000ULL + (uint64_t) k) {
                fail++;
                uart_printf("satp slot %d: %lx\n", k, (unsigned long) got);
            }
        }
    }

    for (int i = 0; i < N / 2; i++) {
        ddr_slots[2 * i] = 0x5A5A000000000000ULL + (uint64_t) (2 * i);
        ddr_slots[2 * i + 1] = 0x5A5A000000000000ULL + (uint64_t) (2 * i + 1);
        uint64_t ms = csr_read(mstatus);
        csr_write(mstatus, ms ^ (1ULL << 18)); /* SUM value change -> flush */
        csr_write(mstatus, ms);                /* restore (a second flush) */
        for (int k = 2 * i; k <= 2 * i + 1; k++) {
            uint64_t got = ddr_slots[k];
            if (got != 0x5A5A000000000000ULL + (uint64_t) k) {
                fail++;
                uart_printf("sum slot %d: %lx\n", k, (unsigned long) got);
            }
        }
    }

    uart_puts(fail ? "<<FAIL>>\n" : "<<PASS>>\n");
    for (;;) {
    }
    return 0;
}
