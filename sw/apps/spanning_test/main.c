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
 * Spanning instruction test: 32-bit instructions that straddle a fetch word
 * boundary must execute correctly. With the compressed extension the
 * instruction stream mixes 16-bit and 32-bit encodings, so a 32-bit
 * instruction can start in the upper half of one word and finish in the next.
 *
 * Tests 1-3 format strings with snprintf, compiled with the C extension like
 * the rest of the program, and compare each with its expected text. Test 4
 * runs span_chain (spanning.S), whose 32-bit instructions all start at
 * PC[1]=1, and compares its results with span_chain_ref.
 */
#include <stdint.h>

#include "sprintf.h"
#include "string.h"
#include "uart.h"

uint64_t span_chain(uint64_t x, uint64_t *scratch);

/* The computation span_chain performs. */
static uint64_t span_chain_ref(uint64_t x)
{
    uint64_t t0 = x + 0x123u;
    uint64_t t1 = t0 ^ 0x5A5u;
    t0 = (t1 << 7) + x;
    t1 = t0 - t1;
    t0 = t1 ^ 0x12345000u;
    t1 = t0 * x;
    /* The reload of t1 matches it, so bne falls through and beq is taken. */
    return t0 + 0x7FFu + (t1 >> 3);
}

static int failures;

static void check_text(const char *got, const char *want)
{
    uart_printf("%s", got);
    if (strcmp(got, want) == 0) {
        uart_puts(" OK\n");
    } else {
        uart_printf(" FAIL (want \"%s\")\n", want);
        failures++;
    }
}

int main(void)
{
    static const uint64_t span_inputs[] = {0x0123456789ABCDEFull, 0xFEDCBA9876543210ull, 42u};
    char buf[32];
    int len;
    int span_ok = 1;
    uint64_t scratch;

    uart_puts("=== Spanning Instruction Test ===\n");

    uart_puts("Test 1: snprintf with string... ");
    snprintf(buf, sizeof buf, "%s", "Hello");
    check_text(buf, "Hello");

    /* The loop repeats the call, covering PC handling across iterations. */
    uart_puts("Test 2: snprintf in loop... ");
    len = 0;
    for (int i = 0; i < 3; i++) {
        len += snprintf(buf + len, sizeof buf - (size_t) len, "%d", i);
    }
    check_text(buf, "012");

    uart_puts("Test 3: complex snprintf... ");
    snprintf(buf, sizeof buf, "%s=%d", "val", 42);
    check_text(buf, "val=42");

    uart_puts("Test 4: spanning sequence... ");
    for (unsigned i = 0; i < sizeof span_inputs / sizeof span_inputs[0]; i++) {
        uint64_t got = span_chain(span_inputs[i], &scratch);
        uint64_t want = span_chain_ref(span_inputs[i]);
        if (got != want) {
            uart_printf("\n  x=0x%016llx got 0x%016llx want 0x%016llx",
                        (unsigned long long) span_inputs[i],
                        (unsigned long long) got,
                        (unsigned long long) want);
            span_ok = 0;
        }
    }
    if (span_ok) {
        uart_puts("OK\n");
    } else {
        uart_puts("\n  FAIL\n");
        failures++;
    }

    if (failures == 0) {
        uart_puts("\n=== All Tests Passed ===\n");
        uart_puts("<<PASS>>\n");
    } else {
        uart_puts("\n=== SOME TESTS FAILED ===\n");
        uart_puts("<<FAIL>>\n");
    }

    for (;;) {
    }
}
