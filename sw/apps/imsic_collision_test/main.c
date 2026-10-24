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

/* A burst of APLIC MSIs overlaps claims and pending-bit clears. Identity 9
 * marks the end of the burst; identity 7 coalesces the four earlier offers.
 */
#include "aplic.h"
#include "imsic.h"
#include "uart.h"

#define PENDING (1ul << 7)
#define MARKER (1ul << 9)
#define TOPEI(id) (((unsigned long) (id) << 16) | (id))

#define BURST(delay, operation)                                                                    \
    __asm__ volatile(".option push\n.option norvc\n"                                               \
                     "sw %1, 0(%2)\n.rept " #delay "\n nop\n.endr\n" operation "\n.option pop\n"   \
                     : "=r"(old)                                                                   \
                     : "r"(0x3Eu), "r"(&APLIC_SETIP(APLIC_M_BASE)), "r"(PENDING)                   \
                     : "memory")

#define PHASE(n)                                                                                   \
    case n:                                                                                        \
        if (claim) {                                                                               \
            BURST(n, "csrrw %0, 0x35c, zero");                                                     \
        } else {                                                                                   \
            BURST(n, "csrrc %0, 0x351, %3");                                                       \
        }                                                                                          \
        break

static unsigned long burst(unsigned int delay, int claim)
{
    unsigned long old = 0;
    switch (delay) {
        PHASE(0);
        PHASE(1);
        PHASE(2);
        PHASE(3);
        PHASE(4);
        PHASE(5);
        PHASE(6);
        PHASE(7);
        PHASE(8);
        PHASE(9);
        PHASE(10);
        PHASE(11);
        PHASE(12);
        PHASE(13);
        PHASE(14);
        PHASE(15);
    }
    return old;
}

int main(void)
{
    int ok = 1;
    csr_write(mie, 0);
    csr_write(mideleg, 0);
    imsic_write(0, IMSIC_EIE0, PENDING | MARKER);
    imsic_write(0, IMSIC_EIDELIVERY, 1);
    APLIC_DOMAINCFG(APLIC_M_BASE) = APLIC_DOMAINCFG_IE | APLIC_DOMAINCFG_DM;
    for (unsigned int source = 1; source <= APLIC_NUM_SOURCES; source++) {
        APLIC_SOURCECFG(APLIC_M_BASE, source) = APLIC_SOURCE_DETACHED;
        APLIC_TARGET(APLIC_M_BASE, source) = source == APLIC_NUM_SOURCES ? 9 : 7;
        APLIC_SETIENUM(APLIC_M_BASE) = source;
    }
    for (int claim = 0; claim < 2; claim++) {
        for (unsigned int delay = 0; delay < 16; delay++) {
            /* Leave miselect on EIP0 for the raw CSR clear in burst(). */
            imsic_write(0, IMSIC_EIP0, PENDING);
            int phase_ok = imsic_top(0) == TOPEI(7);
            unsigned long old = burst(delay, claim);
            phase_ok &=
                claim ? old == TOPEI(7) : (old & PENDING) != 0 && (old & ~(PENDING | MARKER)) == 0;
            unsigned long pending = 0;
            for (unsigned int wait = 0; wait < 1000; wait++) {
                pending = imsic_read(0, IMSIC_EIP0);
                if (pending & MARKER)
                    break;
            }
            phase_ok &= (pending & MARKER) != 0;
            phase_ok &= (pending & ~(PENDING | MARKER)) == 0;
            /* The marker follows every identity-7 offer, so no late MSI
             * may refill the file while these reported identities drain.
             */
            if (pending & PENDING)
                phase_ok &= imsic_claim(0) == TOPEI(7);
            phase_ok &= imsic_claim(0) == TOPEI(9);
            phase_ok &= imsic_claim(0) == 0;
            if (!phase_ok)
                uart_printf("claim=%d delay=%u old=%lx pending=%lx\n", claim, delay, old, pending);
            ok &= phase_ok;
        }
    }
    uart_puts(ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    return 0;
}
