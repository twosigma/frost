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
 * Directed CSR test.
 *
 * Tests 1-3: writes mstatus with MIE=1 and checks that execution continues
 * past the write.
 *
 * Tests 4-7 (Phase 3 M7): the M-mode counter controls that OpenSBI's SBI PMU
 * and Sstc setup depend on. mcountinhibit exists and is WARL over {CY, IR};
 * CY stops cycle and IR stops instret while set; mcycle and minstret accept
 * full 64-bit M-mode writes that the user views (cycle/instret) then reflect;
 * and M-mode reads of the writable aliases cost no ticks (the commit stage
 * raises the CSR write enable for pure reads too).
 *
 * The UART helpers are inline here rather than taken from lib/uart.c, so that a
 * fault in the library cannot mask or cause a failure on the CSR path under
 * test.
 */

#include <stdint.h>

#define UART_BASE 0x40000000
volatile uint8_t *uart = (volatile uint8_t *) UART_BASE;

static inline void uart_putc(char c)
{
    *uart = c;
}

static inline void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static inline void uart_hex(uint32_t val)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4) {
        uart_putc(hex[(val >> i) & 0xF]);
    }
}

static inline void uart_hex64(uint64_t val)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = 60; i >= 0; i -= 4) {
        uart_putc(hex[(val >> i) & 0xF]);
    }
}

static int g_failed;

/* Report one named check; a failure is remembered for the final verdict. */
static void check(const char *name, int ok)
{
    uart_puts(ok ? "  ok   " : "  FAIL ");
    uart_puts(name);
    uart_puts("\r\n");
    if (!ok)
        g_failed = 1;
}

/* CSR helpers by numeric address (the toolchain names mcountinhibit, but the
 * numeric form keeps the test independent of assembler spellings). */
#define CSR_MCOUNTINHIBIT 0x320
#define CSR_MCYCLE 0xB00
#define CSR_MINSTRET 0xB02
#define CSR_CYCLE 0xC00
#define CSR_INSTRET 0xC02
#define csr_read(csr)                                                                              \
    ({                                                                                             \
        uint64_t __v;                                                                              \
        __asm volatile("csrr %0, " #csr : "=r"(__v));                                              \
        __v;                                                                                       \
    })
#define csr_write(csr, v) __asm volatile("csrw " #csr ", %0" ::"r"((uint64_t) (v)))
#define csr_set(csr, v) __asm volatile("csrs " #csr ", %0" ::"r"((uint64_t) (v)))
#define csr_clear(csr, v) __asm volatile("csrc " #csr ", %0" ::"r"((uint64_t) (v)))

/* Burn a few instructions so instret has something to count (or not). */
static void spin(void)
{
    for (volatile int i = 0; i < 16; i++)
        ;
}

/* READ_LOOP_COUNT back-to-back reads of one CSR, bracketed by reads of the
 * same CSR; returns the bracket delta. A read that costs a tick shows up as a
 * delta short by READ_LOOP_COUNT, far outside READ_LOOP_TOLERANCE. */
#define READ_LOOP_COUNT 512
#define READ_LOOP_TOLERANCE 64

static uint64_t read_loop_delta(unsigned csr)
{
    uint64_t start, end, scratch;
    int i;

    switch (csr) {
        case 0xC00:
            __asm volatile("csrr %0, 0xC00" : "=r"(start));
            for (i = 0; i < READ_LOOP_COUNT; i++)
                __asm volatile("csrr %0, 0xC00" : "=r"(scratch));
            __asm volatile("csrr %0, 0xC00" : "=r"(end));
            break;
        case 0xB00:
            __asm volatile("csrr %0, 0xB00" : "=r"(start));
            for (i = 0; i < READ_LOOP_COUNT; i++)
                __asm volatile("csrr %0, 0xB00" : "=r"(scratch));
            __asm volatile("csrr %0, 0xB00" : "=r"(end));
            break;
        case 0xC02:
            __asm volatile("csrr %0, 0xC02" : "=r"(start));
            for (i = 0; i < READ_LOOP_COUNT; i++)
                __asm volatile("csrr %0, 0xC02" : "=r"(scratch));
            __asm volatile("csrr %0, 0xC02" : "=r"(end));
            break;
        default:
            __asm volatile("csrr %0, 0xB02" : "=r"(start));
            for (i = 0; i < READ_LOOP_COUNT; i++)
                __asm volatile("csrr %0, 0xB02" : "=r"(scratch));
            __asm volatile("csrr %0, 0xB02" : "=r"(end));
            break;
    }
    (void) scratch;
    return end - start;
}

static void counter_tests(void)
{
    uint64_t a, b, c;

    uart_puts("\r\nTest 4: mcountinhibit exists and is WARL over {CY, IR}\r\n");
    a = csr_read(0x320);
    check("reset value is 0", a == 0);
    csr_write(0x320, 0xFFFFFFFFFFFFFFFFull);
    a = csr_read(0x320);
    uart_puts("  all-ones write reads ");
    uart_hex64(a);
    uart_puts("\r\n");
    check("only CY and IR stick (0x5)", a == 0x5);
    csr_write(0x320, 0);
    check("clears to 0", csr_read(0x320) == 0);

    uart_puts("\r\nTest 5: CY stops cycle, IR stops instret\r\n");
    csr_set(0x320, 0x1); /* CY */
    a = csr_read(0xC00);
    spin();
    b = csr_read(0xC00);
    check("cycle frozen while CY=1", a == b);
    c = csr_read(0xC02);
    spin();
    check("instret still counts while only CY=1", csr_read(0xC02) > c);
    csr_clear(0x320, 0x1);
    a = csr_read(0xC00);
    spin();
    check("cycle runs again after CY cleared", csr_read(0xC00) > a);

    csr_set(0x320, 0x4); /* IR */
    a = csr_read(0xC02);
    spin();
    b = csr_read(0xC02);
    check("instret frozen while IR=1", a == b);
    c = csr_read(0xC00);
    spin();
    check("cycle still counts while only IR=1", csr_read(0xC00) > c);
    csr_clear(0x320, 0x4);
    a = csr_read(0xC02);
    spin();
    check("instret runs again after IR cleared", csr_read(0xC02) > a);

    uart_puts("\r\nTest 6: mcycle/minstret are 64-bit writable from M-mode\r\n");
    /* Read both views back to back, before any printing, so the bounds
     * only have to cover the few cycles between two csrr instructions. */
    csr_write(0xB00, 0x8000000012345678ull); /* Linux starts counting events at 2^63 */
    a = csr_read(0xC00);
    b = csr_read(0xB00);
    uart_puts("  cycle/mcycle after the mcycle write: ");
    uart_hex64(a);
    uart_putc(' ');
    uart_hex64(b);
    uart_puts("\r\n");
    check("cycle reflects the written value",
          a >= 0x8000000012345678ull && a < 0x8000000012345678ull + 256);
    check("mcycle reads the same counter", b >= a && b < a + 256);
    csr_write(0xB02, 0x7FFFFFFFFFFFFFF0ull);
    a = csr_read(0xC02);
    spin();
    b = csr_read(0xB02);
    uart_puts("  instret/minstret after the minstret write: ");
    uart_hex64(a);
    uart_putc(' ');
    uart_hex64(b);
    uart_puts("\r\n");
    check("instret reflects the written value",
          a >= 0x7FFFFFFFFFFFFFF0ull && a < 0x7FFFFFFFFFFFFFF0ull + 8);
    check("minstret reads the same counter and advances", b > a && b < a + 512);
    /* Read-modify-write forms compose over the live counter. */
    csr_write(0xB00, 0x100);
    csr_set(0xB00, 0x8000000000000000ull);
    a = csr_read(0xB00);
    check("csrs composes over the live mcycle",
          a >= 0x8000000000000100ull && a < 0x8000000000000100ull + 256);
    csr_write(0xB00, 0);
    a = csr_read(0xC00);
    check("mcycle write of 0 restarts from 0", a < 256);

    uart_puts("\r\nTest 7: M-mode reads of mcycle/minstret are pure reads\r\n");
    /* The commit stage raises the CSR write enable for every CSR
     * instruction. If a csrr of the M-mode alias were treated as a write of
     * the value it read, every read would swallow one cycle tick (and drop
     * the staged retirements for minstret). Time the same read loop against
     * the M alias and the read-only alias: they must agree closely. */
    c = read_loop_delta(0xC00);
    a = read_loop_delta(0xB00);
    uart_puts("  cycle-loop deltas via cycle/mcycle: ");
    uart_hex64(c);
    uart_putc(' ');
    uart_hex64(a);
    uart_puts("\r\n");
    check("mcycle reads cost no ticks", a + READ_LOOP_TOLERANCE > c && a < c + READ_LOOP_TOLERANCE);
    c = read_loop_delta(0xC02);
    a = read_loop_delta(0xB02);
    uart_puts("  instret-loop deltas via instret/minstret: ");
    uart_hex64(c);
    uart_putc(' ');
    uart_hex64(a);
    uart_puts("\r\n");
    check("minstret reads drop no retirements",
          a + READ_LOOP_TOLERANCE > c && a < c + READ_LOOP_TOLERANCE);
}

int main(void)
{
    uint32_t val;

    uart_puts("\r\n=== CSR Test ===\r\n");

    __asm volatile("csrr %0, mstatus" : "=r"(val));
    uart_puts("Initial mstatus: ");
    uart_hex(val);
    uart_puts("\r\n");

    __asm volatile("csrr %0, mie" : "=r"(val));
    uart_puts("mie: ");
    uart_hex(val);
    uart_puts("\r\n");

    __asm volatile("csrr %0, mip" : "=r"(val));
    uart_puts("mip: ");
    uart_hex(val);
    uart_puts("\r\n");

    /* Test 1: write mstatus with MIE=0, the baseline case. */
    uart_puts("\r\nTest 1: csrw mstatus with MIE=0\r\n");
    uart_putc('A');
    __asm volatile("csrw mstatus, %0" ::"r"(0x00001800)); /* MPP=11, MIE=0 */
    uart_putc('B');
    uart_puts(" - PASS (MIE=0 works)\r\n");

    __asm volatile("csrr %0, mstatus" : "=r"(val));
    uart_puts("mstatus after: ");
    uart_hex(val);
    uart_puts("\r\n");

    /* Test 2: write mstatus with MIE=1, the case this test was written for. */
    uart_puts("\r\nTest 2: csrw mstatus with MIE=1\r\n");
    uart_putc('C');
    uart_puts(" - About to set MIE=1...\r\n");

    __asm volatile("csrw mstatus, %0" ::"r"(0x00001808)); /* MPP=11, MIE=1 */

    /* Reaching this line means the MIE=1 write did not wedge the core. */
    uart_putc('D');
    uart_puts(" - PASS (MIE=1 works!)\r\n");

    __asm volatile("csrr %0, mstatus" : "=r"(val));
    uart_puts("mstatus after: ");
    uart_hex(val);
    uart_puts("\r\n");

    /* Test 3: Read mip again to confirm no spurious interrupts */
    __asm volatile("csrr %0, mip" : "=r"(val));
    uart_puts("mip after: ");
    uart_hex(val);
    uart_puts("\r\n");

    counter_tests();

    if (g_failed) {
        uart_puts("\r\n=== Counter tests FAILED ===\r\n");
        uart_puts("<<FAIL>>\r\n");
        for (;;)
            ;
    }

    uart_puts("\r\n=== All Tests PASSED ===\r\n");
    uart_puts("<<PASS>>\r\n");

    for (;;)
        ;

    return 0;
}
