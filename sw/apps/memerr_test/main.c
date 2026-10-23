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
 * Memory error unit test, for simulation: error responses from the DDR model
 * and ECC reports from the bench reach the unit's registers and its interrupt,
 * APLIC source 5.
 *
 * The registry entry passes +axi_rd_error_addr and +axi_wr_error_addr, so the
 * DDR model answers SLVERR to every read of RD_ERROR_LINE and every write of
 * WR_ERROR_LINE. A write reaches DDR only when the L2 evicts the line, so the
 * test writes the line, has fence.i write the L1D back to the L2, and then
 * reads eight lines that share its L2 set. The read fault is handled precisely;
 * the final writeback error must stop the CPU with a sticky fatal indication. The bench plays the
 * X3's ECC reader (test_real_program.py, EccReportDriver): it holds i_ecc_present high and, once
 * IRQ_EN enables both ECC kinds, reports the corrected and uncorrectable errors and polls this
 * program expects.
 */

#include <stdint.h>

#include "aplic.h"
#include "csr.h"
#include "memory_error.h"
#include "trap.h"

/* Region offsets 16 MiB and 32 MiB, matching the registry's plusargs. */
#define RD_ERROR_LINE 0x81000000ul
#define WR_ERROR_LINE 0x82000000ul
#define L2_SET_STRIDE (2ul << 20) /* frost.sv L2_CACHE_BYTES: one way's span */
#define EVICT_LINES 8

/* What EccReportDriver reports. */
#define BENCH_CE_TOTAL 5u
#define BENCH_CE_ADDR 0x80001240ul
#define BENCH_UE_ADDR 0x87654300ul
#define BENCH_POLLS 4u

#define AXI_RESP_SLVERR 2u
#define WAIT_LOOPS 200000

static void uart_puts(const char *s)
{
    while (*s)
        UART_TX = (uint8_t) *s++;
}

static void uart_hex(unsigned long v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = (int) (sizeof(unsigned long) * 8) - 4; i >= 0; i -= 4)
        UART_TX = (uint8_t) hex[(v >> i) & 0xF];
}

static int g_ok = 1;

static void check(const char *name, unsigned long got, unsigned long want)
{
    uart_puts(got == want ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts(" got=");
    uart_hex(got);
    uart_puts(" want=");
    uart_hex(want);
    uart_puts("\r\n");
    if (got != want)
        g_ok = 0;
}

/* ---- Interrupt: claim, note and clear the unit's status ---- */
static volatile uint32_t g_irq_count;
static volatile uint32_t g_status_seen;
static volatile uint32_t g_other_claims;
static volatile uint32_t g_expected_read_fault;
static volatile uint32_t g_read_faults;

__attribute__((noinline, used)) void memerr_irq_c(void)
{
    unsigned long cause = csr_read(mcause);
    if (!(cause >> 63)) {
        if (cause == 5 && g_expected_read_fault) {
            g_expected_read_fault = 0;
            g_read_faults++;
            /* The deliberate faulting LD below is explicitly noncompressed. */
            csr_write(mepc, csr_read(mepc) + 4);
            return;
        }
        uart_puts("[FAIL] exception mcause=");
        uart_hex(cause);
        uart_puts(" mepc=");
        uart_hex(csr_read(mepc));
        uart_puts("\r\n<<FAIL>>\r\n");
        for (;;) {
        }
    }
    uint32_t claim = aplic_claim_machine();
    if (claim == MEMORY_ERROR_APLIC_SOURCE) {
        uint32_t status = memory_error_read32(MEMORY_ERROR_STATUS);
        g_status_seen |= status;
        memory_error_write32(MEMORY_ERROR_STATUS, status); /* drops the level */
        g_irq_count++;
    } else {
        g_other_claims++;
    }
}

__attribute__((naked, aligned(4))) static void memerr_irq_entry(void)
{
    __asm__ volatile("addi sp, sp, -128\n"
                     "sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n"
                     "sd a0, 32(sp)\n sd a1, 40(sp)\n sd a2, 48(sp)\n sd a3, 56(sp)\n"
                     "sd a4, 64(sp)\n sd a5, 72(sp)\n sd a6, 80(sp)\n sd a7, 88(sp)\n"
                     "sd t3, 96(sp)\n sd t4, 104(sp)\n sd t5, 112(sp)\n sd t6, 120(sp)\n"
                     "call memerr_irq_c\n"
                     "ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n"
                     "ld a0, 32(sp)\n ld a1, 40(sp)\n ld a2, 48(sp)\n ld a3, 56(sp)\n"
                     "ld a4, 64(sp)\n ld a5, 72(sp)\n ld a6, 80(sp)\n ld a7, 88(sp)\n"
                     "ld t3, 96(sp)\n ld t4, 104(sp)\n ld t5, 112(sp)\n ld t6, 120(sp)\n"
                     "addi sp, sp, 128\n"
                     "mret\n");
}

/* Wait until a register reads want, and return what it reads. */
static uint32_t wait_reg(uint32_t offset, uint32_t want)
{
    uint32_t value = 0;
    for (int i = 0; i < WAIT_LOOPS; i++) {
        value = memory_error_read32(offset);
        if (value == want)
            break;
    }
    return value;
}

static uint32_t wait_seen(uint32_t bits)
{
    for (int i = 0; i < WAIT_LOOPS; i++) {
        if ((g_status_seen & bits) == bits)
            break;
    }
    return g_status_seen & bits;
}

int main(void)
{
    uart_puts("\r\n=== Memory error unit test ===\r\n");

    /* Reset state; the bench's reader is present. */
    uint32_t caps = memory_error_read32(MEMORY_ERROR_CAPS);
    check("caps-ecc", caps & MEMORY_ERROR_CAPS_ECC, MEMORY_ERROR_CAPS_ECC);
    check("caps-version", MEMORY_ERROR_CAPS_VERSION(caps), 1);
    check("status-reset", memory_error_read32(MEMORY_ERROR_STATUS), 0);
    check("ce-count-reset", memory_error_read32(MEMORY_ERROR_CE_COUNT), 0);
    check("rd-errs-reset", memory_error_read32(MEMORY_ERROR_AXI_RD_ERRS), 0);
    check("unmapped-reads-zero", memory_error_read32(0x40u), 0);

    set_trap_handler(memerr_irq_entry);
    aplic_enable_machine_source(MEMORY_ERROR_APLIC_SOURCE);
    memory_error_write32(MEMORY_ERROR_IRQ_EN, MEMORY_ERROR_AXI_RD | MEMORY_ERROR_AXI_WR);
    enable_external_interrupt();
    /* Keep MIE clear until the expected access fault has been handled. The
     * DDR monitor raises its interrupt before the failed fill returns through
     * both cache levels; servicing it first would restart the failing load. */

    /* A failed fill raises a precise access fault and never installs data. */
    g_expected_read_fault = 1;
    __asm__ volatile(".option push\n.option norvc\nld zero, 0(%0)\n.option pop"
                     :
                     : "r"(RD_ERROR_LINE)
                     : "memory");
    enable_interrupts();
    check("read-access-fault", g_read_faults, 1);
    check("rd-errs", wait_reg(MEMORY_ERROR_AXI_RD_ERRS, 1), 1);
    uint32_t axi_err = memory_error_read32(MEMORY_ERROR_AXI_ERR);
    check("rd-err-write-bit", MEMORY_ERROR_AXI_ERR_WRITE(axi_err), 0);
    check("rd-err-resp", MEMORY_ERROR_AXI_ERR_RESP(axi_err), AXI_RESP_SLVERR);
    check("rd-err-irq", wait_seen(MEMORY_ERROR_AXI_RD), MEMORY_ERROR_AXI_RD);
    check("wr-errs-none", memory_error_read32(MEMORY_ERROR_AXI_WR_ERRS), 0);

    /* Enabling both ECC kinds starts the bench's reports. */
    memory_error_write32(MEMORY_ERROR_IRQ_EN, MEMORY_ERROR_ALL);
    check("ce-count", wait_reg(MEMORY_ERROR_CE_COUNT, BENCH_CE_TOTAL), BENCH_CE_TOTAL);
    check("ue-count", wait_reg(MEMORY_ERROR_UE_COUNT, 1), 1);
    check("polls", wait_reg(MEMORY_ERROR_ECC_POLLS, BENCH_POLLS), BENCH_POLLS);
    check("ce-addr", memory_error_read64(MEMORY_ERROR_CE_ADDR), BENCH_CE_ADDR);
    check("ue-addr", memory_error_read64(MEMORY_ERROR_UE_ADDR), BENCH_UE_ADDR);
    uint32_t ecc_bits =
        MEMORY_ERROR_CE | MEMORY_ERROR_UE | MEMORY_ERROR_CE_ADDR_NEW | MEMORY_ERROR_UE_ADDR_NEW;
    check("ecc-irq", wait_seen(ecc_bits), ecc_bits);

    disable_interrupts();
    memory_error_write32(MEMORY_ERROR_IRQ_EN, 0);
    memory_error_write32(MEMORY_ERROR_STATUS, MEMORY_ERROR_ALL);
    check("status-cleared", memory_error_read32(MEMORY_ERROR_STATUS), 0);
    check("other-claims", g_other_claims, 0);

    if (!g_ok) {
        uart_puts("\r\n<<FAIL>>\r\n");
        for (;;) {
        }
    }
    /* A buffered-store writeback error cannot be a precise trap. The bench
     * checks the sticky fatal address, DDR error counter and stopped retirement
     * after this banner; software cannot report success after the fatal stop. */
    uart_puts("\r\n<<EXPECT_FATAL>>\r\n");
    *(volatile uint64_t *) WR_ERROR_LINE = 0x5A5A5A5A5A5A5A5Aul;
    __asm__ volatile("fence.i" ::: "memory");
    for (unsigned long k = 1; k <= EVICT_LINES; k++)
        (void) *(volatile uint64_t *) (WR_ERROR_LINE + k * L2_SET_STRIDE);
    for (;;) {
    }
    return 0;
}
