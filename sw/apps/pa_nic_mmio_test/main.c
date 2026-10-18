/*
 *    Copyright (c) 2026 John Goodacre
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

/* CPU-visible wide NIC register publication through the full FROST top.
 * This checks the MMIO ABI transport, not a packet or a product DMC path. */
#include <stdint.h>

#include "nic.h"
#include "uart.h"

#ifndef FROST_DDR_CAPACITY_LOG2_BYTES
#error FROST_DDR_CAPACITY_LOG2_BYTES must match the RTL build
#endif
#if FROST_DDR_CAPACITY_LOG2_BYTES < 30 || FROST_DDR_CAPACITY_LOG2_BYTES > 37
#error DDR aperture must be one of 1..128 GiB
#endif

#define DDR_END (0x80000000ul + (1ul << FROST_DDR_CAPACITY_LOG2_BYTES))

static uint64_t base_readback(uint32_t offset)
{
    return (uint64_t) nic_read(offset) | ((uint64_t) nic_read(offset + 4u) << 32);
}

int main(void)
{
    const uint64_t rx = DDR_END - 0x3000ul;
    const uint64_t tx = DDR_END - 0x2000ul;
    int failures = 0;
    unsigned wait;

    for (wait = 0; wait < 100000u; ++wait) {
        uint32_t status = nic_read(NIC_STATUS);
        if (!(status & NIC_STATUS_RESET_BUSY) &&
            (status & (NIC_STATUS_RX_IDLE | NIC_STATUS_TX_IDLE)) ==
                (NIC_STATUS_RX_IDLE | NIC_STATUS_TX_IDLE))
            break;
    }
    if (wait == 100000u || nic_read(NIC_ABI_CTRL) != NIC_ABI_WIDE_SUPPORTED) {
        uart_printf("PA NIC wide ABI unavailable\n");
        failures++;
    }
    nic_select_wide();
    if (nic_read(NIC_ABI_CTRL) != (NIC_ABI_WIDE | NIC_ABI_WIDE_SUPPORTED)) {
        uart_printf("PA NIC wide ABI switch failed\n");
        failures++;
    }

    nic_write64(NIC_RX_BASE64, rx);
    nic_write64(NIC_TX_BASE64, tx);
    if (base_readback(NIC_RX_BASE64) != rx || base_readback(NIC_TX_BASE64) != tx) {
        uart_printf("PA NIC wide base readback failed: rx=%lx tx=%lx\n",
                    base_readback(NIC_RX_BASE64), base_readback(NIC_TX_BASE64));
        failures++;
    }
    /* A legacy word write must not tear a live wide address. Neither
     * direction is enabled in this test. */
    nic_write(NIC_RX_BASE, 0x80001000u);
    if (base_readback(NIC_RX_BASE64) != rx || base_readback(NIC_TX_BASE64) != tx) {
        uart_printf("PA NIC wide base torn by legacy write\n");
        failures++;
    }

    uart_printf(failures ? "<<FAIL>>\n" : "<<PASS>>\n");
    for (;;) {
    }
}
