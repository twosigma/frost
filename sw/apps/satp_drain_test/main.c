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
 * Pre-retirement committed-store drain for translation-class CSRs.
 *
 * A store committed immediately before a translation-relevant CSR write must
 * drain before that CSR retires and triggers the full recovery flush. The
 * flush resets the store queue, so retiring first would lose a store that is
 * architecturally committed but still undrained in the cached tier. That is
 * the shape of page-table setup (sd PTE; csrw satp). The env_v demand pager
 * lost its UART megapage PTE this way and livelocked. Every iteration stores
 * to cached DDR, which drains slowly, and writes the CSR in the next few
 * instructions.
 *
 * Case 1: sd to cached DDR; csrw satp (Bare->Bare rewrites still flush per
 *         D10); ld back and compare.
 * Case 2: the same with an mstatus.SUM value toggle, read back after the
 *         recovery flush, then restored and read back after the second flush.
 */

#include <stdint.h>

#include "csr.h"
#include "uart.h"

#define N 64

volatile uint64_t ddr_slots[N] __attribute__((section(".ddr_data"), aligned(64)));

int main(void)
{
    int fail = 0;

    /* Two back-to-back stores per iteration: the cached tier drains one store
     * at a time, so the second is still committed but undrained when the CSR
     * reaches the head. The serializer has to hold the CSR until both drain.
     * The slots are adjacent dwords of one line, the page-table-setup shape. */
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
        uint64_t toggled_ms = ms ^ (1ULL << 18);
        csr_write(mstatus, toggled_ms); /* SUM value change -> flush */
        if ((csr_read(mstatus) ^ toggled_ms) & (1ULL << 18)) {
            fail++;
            uart_puts("mstatus SUM toggle did not survive recovery\n");
        }
        csr_write(mstatus, ms); /* restore (a second flush) */
        if ((csr_read(mstatus) ^ ms) & (1ULL << 18)) {
            fail++;
            uart_puts("mstatus SUM restore did not survive recovery\n");
        }
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
