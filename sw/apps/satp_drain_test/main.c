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
 * Committed stores must drain before translation CSR writes retire and
 * flush the pipeline. A flush empties the store queue; flushing before the
 * drain would lose committed stores, as in page-table setup followed by
 * csrw satp. Test cached-DDR stores followed by satp writes and mstatus.SUM
 * changes. Even a Bare-to-Bare satp write must flush.
 */

#include <stdint.h>

#include "csr.h"
#include "uart.h"

#define N 64

volatile uint64_t ddr_slots[N] __attribute__((section(".ddr_data"), aligned(64)));

int main(void)
{
    int fail = 0;

    /* Adjacent dword stores model page-table setup. The cached tier drains
     * one store at a time; the CSR must wait for both committed stores. */
    for (int i = 0; i < N / 2; i++) {
        ddr_slots[2 * i] = 0xA5A5000000000000ULL + (uint64_t) (2 * i);
        ddr_slots[2 * i + 1] = 0xA5A5000000000000ULL + (uint64_t) (2 * i + 1);
        csr_write(satp, 0); /* Bare->Bare: still a full flush */
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
