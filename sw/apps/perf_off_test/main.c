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
 * Profiling counters absent: the production configuration (PERF_COUNTERS=0).
 *
 * The custom mperf* CSRs still decode but hold no state: mperfsel and
 * mperfctl ignore writes, all five read zero, and the profiling library sees
 * zero counters. The Zicntr counters (cycle, instret) are untouched by the
 * option and must keep counting. Each check reports over UART; the run ends
 * with <<PASS>> or <<FAIL>>.
 */

#include <stdint.h>

#include "tomasulo_profile.h"

static int g_ok = 1;

static void check(const char *name, unsigned long got, unsigned long want)
{
    int ok = (got == want);
    if (!ok)
        g_ok = 0;
    uart_printf("%s %s: got=%lx want=%lx\n", ok ? "[PASS]" : "[FAIL]", name, got, want);
}

static tomasulo_profile_snapshot_t snapshot;

int main(void)
{
    unsigned long old;
    uint64_t cycles_before, cycles_after, instret_before, instret_after;
    volatile uint32_t spin = 0;

    uart_printf("perf_off_test: profiling counters absent\n");

    check("mperfcount reads zero", csr_read_imm(CSR_MPERFCOUNT), 0);

    csr_write_imm(CSR_MPERFSEL, 7U);
    check("mperfsel ignores csrw", csr_read_imm(CSR_MPERFSEL), 0);
    __asm__ volatile("li t0, 0x55\n\tcsrrs %0, %1, t0" : "=r"(old) : "i"(CSR_MPERFSEL) : "t0");
    check("mperfsel csrrs returns zero", old, 0);
    check("mperfsel ignores csrrs", csr_read_imm(CSR_MPERFSEL), 0);

    csr_write_imm(CSR_MPERFCTL, 3U);
    check("mperfctl reads zero", csr_read_imm(CSR_MPERFCTL), 0);
    check("mperfdata reads zero", csr_read_imm(CSR_MPERFDATA), 0);
    check("mperfdatah reads zero", csr_read_imm(CSR_MPERFDATAH), 0);

    tomasulo_profile_take_snapshot(&snapshot);
    check("library sees no counters", snapshot.counter_count, 0);

    cycles_before = rdcycle64();
    instret_before = rdinstret64();
    for (uint32_t i = 0; i < 64U; i++)
        spin += i;
    cycles_after = rdcycle64();
    instret_after = rdinstret64();
    check("cycle keeps counting", cycles_after > cycles_before, 1);
    check("instret keeps counting", instret_after > instret_before, 1);

    uart_printf(g_ok ? "\n<<PASS>>\n" : "\n<<FAIL>>\n");
    for (;;) {
    }
    return 0;
}
