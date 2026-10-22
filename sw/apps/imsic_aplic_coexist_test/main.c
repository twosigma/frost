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

/* APLIC wired interrupts and per-level IMSIC delivery selection. */
#include "aplic.h"
#include "dma_engine.h"
#include "imsic.h"
#include "trap.h"
#include "uart.h"

#define NS_IER (*(volatile uint32_t *) 0x40001004ul)
#define EXTERNAL_MASK ((1ul << 11) | (1ul << 9))
static unsigned int checks, failures;
static volatile uint32_t *const dma_data = (volatile uint32_t *) 0x81002000ul;
static void check(const char *name, unsigned long got, unsigned long want)
{
    checks++;
    if (got != want) {
        failures++;
        uart_printf("[FAIL] %s got=%lx want=%lx\n", name, got, want);
    }
}
static unsigned long pending(unsigned long want)
{
    for (unsigned int n = 0; n < 20000; n++)
        if ((csr_read(mip) & EXTERNAL_MASK) == want)
            return want;
    return csr_read(mip) & EXTERNAL_MASK;
}
static void dma_start(void)
{
    dma_engine_ack();
    dma_engine_setup(
        0, (uintptr_t) dma_data, 32, DMA_ENGINE_MODE_FILL | DMA_ENGINE_MODE_IRQ, 0x1234, 0, 0);
    dma_engine_start();
    check("DMA completion", dma_engine_wait(), DMA_ENGINE_STATUS_DONE | DMA_ENGINE_STATUS_IRQ);
    __asm__ volatile("fence rw, rw" ::: "memory");
    check("DMA data", dma_data[7], 0x123b);
}
int main(void)
{
    csr_write(mie, 0ul);
    csr_write(mideleg, 0ul);
    check("M reset direct", imsic_read(0, IMSIC_EIDELIVERY), 0x40000000);
    check("S reset direct", imsic_read(1, IMSIC_EIDELIVERY), 0x40000000);
    aplic_enable_machine_source(1);
    NS_IER = 2;
    check("UART direct MEIP", pending(1ul << 11), 1ul << 11);
    check("UART direct claim", aplic_claim_machine(), 1);
    check("direct line has no file identity", imsic_top(0), 0);
    NS_IER = 0;
    check("UART cleared", pending(0), 0);
    aplic_enable_machine_source(3);
    dma_start();
    check("DMA direct MEIP", pending(1ul << 11), 1ul << 11);
    check("DMA direct claim", aplic_claim_machine(), 3);
    dma_engine_ack();
    check("DMA cleared", pending(0), 0);

    /* M accepts software MSIs while S still accepts the wired DMA line. */
    imsic_write(0, IMSIC_EIE0, 1ul << 21);
    imsic_write(0, IMSIC_EIDELIVERY, 1);
    APLIC_SOURCECFG(APLIC_M_BASE, 3) = APLIC_SOURCE_DELEGATE;
    APLIC_SOURCECFG(APLIC_S_BASE, 3) = APLIC_SOURCE_LEVEL_HIGH;
    APLIC_TARGET(APLIC_S_BASE, 3) = 1;
    APLIC_SETIENUM(APLIC_S_BASE) = 3;
    APLIC_IDELIVERY(APLIC_S_BASE) = 1;
    APLIC_DOMAINCFG(APLIC_S_BASE) = APLIC_DOMAINCFG_IE;
    NS_IER = 2;
    check("M direct line detached", pending(0), 0);
    check("M direct source still pending", APLIC_TOPI(APLIC_M_BASE), 0x10001);
    dma_start();
    check("S direct DMA", pending(1ul << 9), 1ul << 9);
    imsic_send(0, 0, 21);
    check("M file and S direct", pending(EXTERNAL_MASK), EXTERNAL_MASK);
    check("M file claim", imsic_claim(0), 0x150015);
    check("S file has no identity", imsic_claim(1), 0);
    check("S direct survives file claim", pending(1ul << 9), 1ul << 9);
    check("S direct claim", APLIC_CLAIMI(APLIC_S_BASE), 0x30001);
    dma_engine_ack();
    check("S direct cleared", pending(0), 0);
    imsic_write(0, IMSIC_EIDELIVERY, 0x40000000);
    check("M direct restored", pending(1ul << 11), 1ul << 11);
    NS_IER = 0;
    check("all quiet", pending(0), 0);
    uart_printf("IMSIC/APLIC checks: %u passed, %u failed\n", checks - failures, failures);
    uart_puts(failures ? "<<FAIL>>\n" : "<<PASS>>\n");
    for (;;) {
    }
}
