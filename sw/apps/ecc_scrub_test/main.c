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
 * A clean read must not write DDR; eight atomic no-ops must dirty the line.
 * The DDR image supplies the pattern without a CPU store. The registry's
 * +axi_wr_error_addr=0 makes writes of that line return SLVERR, and a failed
 * writeback stops the CPU. The clean eviction must therefore leave AXI_WR_ERRS
 * at zero with the program still running, and the scrubbed line's eviction
 * ends the run in a fatal stop that the bench checks. No ECC reports are
 * injected by the bench.
 */

#include <stdint.h>

#include "memory_error.h"

#define LINE_ADDR 0x80000000ul
#define L2_SET_STRIDE (2ul << 20) /* A multiple of one L2 way's span. */
#define EVICT_LINES 8
#define WAIT_LOOPS 4096

static volatile uint64_t line[8] __attribute__((section(".ddr_data"), aligned(64))) = {
    0x5a39c6e187d24bf0ul,
    0x5a39c6e187d24bf1ul,
    0x5a39c6e187d24bf2ul,
    0x5a39c6e187d24bf3ul,
    0x5a39c6e187d24bf4ul,
    0x5a39c6e187d24bf5ul,
    0x5a39c6e187d24bf6ul,
    0x5a39c6e187d24bf7ul,
};

static int g_ok = 1;

static void uart_puts(const char *s)
{
    while (*s)
        UART_TX = (uint8_t) *s++;
}

static void check(const char *name, int ok)
{
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts("\r\n");
    if (!ok)
        g_ok = 0;
}

static void evict(void)
{
    /* fence.i drains both dirty L1D halves to the L2 before set eviction. */
    __asm__ volatile("fence.i" ::: "memory");
    for (unsigned long k = 1; k <= EVICT_LINES; k++)
        (void) *(volatile uint64_t *) (LINE_ADDR + k * L2_SET_STRIDE);
    __asm__ volatile("fence rw, rw" ::: "memory");
}

static uint32_t settled_writes(void)
{
    uint32_t count = 0;

    /* Let outstanding DDR responses arrive, including an unwanted second write. */
    for (int i = 0; i < WAIT_LOOPS; i++)
        count = memory_error_read32(MEMORY_ERROR_AXI_WR_ERRS);
    return count;
}

int main(void)
{
    uint64_t before[8];
    int intact = 1;

    uart_puts("\r\n=== ECC scrub writeback test ===\r\n");
    check("line-address", (uintptr_t) line == LINE_ADDR);
    check("writes-reset", memory_error_read32(MEMORY_ERROR_AXI_WR_ERRS) == 0);

    for (int i = 0; i < 8; i++) {
        before[i] = line[i];
        if (before[i] != (0x5a39c6e187d24bf0ul ^ (unsigned long) i))
            intact = 0;
    }
    check("loaded-pattern", intact);
    evict();
    check("clean-read-no-writeback", settled_writes() == 0);

    for (int i = 0; i < 8; i++) {
        before[i] = line[i];
        __asm__ volatile("amoadd.d zero, zero, %0" : "+A"(line[i]) : : "memory");
    }
    intact = 1;
    for (int i = 0; i < 8; i++) {
        if (line[i] != before[i])
            intact = 0;
    }
    check("scrub-preserves-data", intact);
    check("no-read-errors", memory_error_read32(MEMORY_ERROR_AXI_RD_ERRS) == 0);
    if (!g_ok) {
        uart_puts("\r\n<<FAIL>>\r\n");
        for (;;) {
        }
    }

    /* The bench checks the fatal address, the one failed write and stopped
     * retirement after this banner. */
    uart_puts("\r\n<<EXPECT_FATAL>>\r\n");
    evict();
    (void) settled_writes();
    /* Reached only if the eviction wrote nothing. */
    check("scrub-writeback", 0);
    uart_puts("\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
