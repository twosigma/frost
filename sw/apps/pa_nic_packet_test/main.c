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

/* Full-top CPU -> high-DDR descriptors -> coherent NIC DMA -> MAC loopback.
 * The FROST_WIDE_DDR_TEST sparse model is not product DMC/DDR or board proof. */
#include <stdint.h>

#include "nic.h"
#include "uart.h"

#ifndef FROST_DDR_CAPACITY_LOG2_BYTES
#error FROST_DDR_CAPACITY_LOG2_BYTES must match the RTL build
#endif
#if FROST_DDR_CAPACITY_LOG2_BYTES < 30 || FROST_DDR_CAPACITY_LOG2_BYTES > 37
#error DDR aperture must be one of 1..128 GiB
#endif

#define DDR_BASE 0x80000000ul
#define DDR_END (DDR_BASE + (1ul << FROST_DDR_CAPACITY_LOG2_BYTES))
#define RX_RING_ADDR (DDR_END - 0x20000ul)
#define TX_RING_ADDR (DDR_END - 0x1f000ul)
#define RX_BUF_ADDR (DDR_END - 0x10000ul)
#define TX_BUF_ADDR (DDR_END - 0x8000ul)
#define LOW_SENTINEL (DDR_BASE + 0x2000ul)
#define FRAME_BYTES 64u
#define WAIT_READY 4000u
#define WAIT_LINK 12000u
#define WAIT_DESC 100000u

static int wait_status(uint32_t mask, uint32_t value, unsigned budget)
{
    while (budget--) {
        if ((nic_read(NIC_STATUS) & mask) == value)
            return 1;
    }
    return 0;
}

static int wait_done(volatile struct nic_desc64 *desc)
{
    for (unsigned i = 0; i < WAIT_DESC; ++i) {
        if (desc->status & NIC_DESC_DD)
            return 1;
    }
    return 0;
}

static uint8_t frame_byte(unsigned i)
{
    static const uint8_t mac[6] = {0x02, 0x11, 0x22, 0x33, 0x44, 0x55};
    return i < 6 ? mac[i] : (uint8_t) (i * 7u + (i >> 2));
}

int main(void)
{
    volatile struct nic_desc64 *rx = (volatile struct nic_desc64 *) RX_RING_ADDR;
    volatile struct nic_desc64 *tx = (volatile struct nic_desc64 *) TX_RING_ADDR;
    volatile uint8_t *rx_buf = (volatile uint8_t *) RX_BUF_ADDR;
    volatile uint8_t *tx_buf = (volatile uint8_t *) TX_BUF_ADDR;
    volatile uint64_t *sentinel = (volatile uint64_t *) LOW_SENTINEL;
    int failures = 0;

    *sentinel = 0x554433221100ffeeull;
    if (!(nic_read(NIC_PHY_STATUS) & NIC_PHY_STATUS_CLK_SHARED)) {
        uart_printf("PA NIC packet test needs shared MAC simulation clock\n");
        failures++;
    }
    if (!wait_status(NIC_STATUS_RX_READY | NIC_STATUS_TX_READY,
                     NIC_STATUS_RX_READY | NIC_STATUS_TX_READY, WAIT_READY)) {
        uart_printf("PA NIC not ready\n");
        failures++;
    }
    nic_write(NIC_PHY_CTRL, NIC_PHY_CTRL_MAC_LOOPBACK);
    nic_write(NIC_CTRL, NIC_CTRL_RESET);
    if (!wait_status(NIC_STATUS_RESET_BUSY, 0, WAIT_READY) ||
        !wait_status(NIC_STATUS_RX_READY | NIC_STATUS_TX_READY,
                     NIC_STATUS_RX_READY | NIC_STATUS_TX_READY, WAIT_READY)) {
        uart_printf("PA NIC reset/ready failed\n");
        failures++;
    }
    if (nic_read(NIC_ABI_CTRL) != NIC_ABI_WIDE_SUPPORTED) {
        uart_printf("PA NIC wide ABI unavailable\n");
        failures++;
    }
    nic_select_wide();
    if (nic_read(NIC_ABI_CTRL) != (NIC_ABI_WIDE | NIC_ABI_WIDE_SUPPORTED)) {
        uart_printf("PA NIC wide ABI switch failed\n");
        failures++;
    }

    rx[0].addr = RX_BUF_ADDR;
    rx[0].len = 128u;
    rx[0].status = 0;
    tx[0].addr = TX_BUF_ADDR;
    tx[0].len = FRAME_BYTES | NIC_TX_SOP | NIC_TX_EOP;
    tx[0].status = 0;
    for (unsigned i = 0; i < FRAME_BYTES; ++i) {
        tx_buf[i] = frame_byte(i);
        rx_buf[i] = 0xa5u;
    }
    nic_write(NIC_MAC_LO, 0x33221102u);
    nic_write(NIC_MAC_HI, 0x5544u);
    nic_write64(NIC_RX_BASE64, RX_RING_ADDR);
    nic_write(NIC_RX_SIZE, 2u);
    nic_write64(NIC_TX_BASE64, TX_RING_ADDR);
    nic_write(NIC_TX_SIZE, 2u);
    __asm__ volatile("fence w, o" ::: "memory");
    nic_write(NIC_RX_TAIL, 1u);
    nic_write(NIC_CTRL, NIC_CTRL_RX_EN | NIC_CTRL_TX_EN);
    if ((nic_read(NIC_CTRL) & (NIC_CTRL_RX_EN | NIC_CTRL_TX_EN)) !=
        (NIC_CTRL_RX_EN | NIC_CTRL_TX_EN)) {
        uart_printf("PA NIC enable refused: status=%x\n", nic_read(NIC_STATUS));
        failures++;
    }
    unsigned wait;
    for (wait = 0; wait < WAIT_LINK; ++wait) {
        if (nic_read(NIC_LINK) & NIC_LINK_CARRIER)
            break;
    }
    if (wait == WAIT_LINK) {
        uart_printf("PA NIC carrier unavailable: link=%x\n", nic_read(NIC_LINK));
        failures++;
    }
    __asm__ volatile("fence w, o" ::: "memory");
    nic_write(NIC_TX_TAIL, 1u);

    if (!wait_done(tx) || tx[0].status != NIC_DESC_DD) {
        uart_printf("PA NIC TX failed: status=%x head=%u irq=%x\n",
                    tx[0].status, nic_read(NIC_TX_HEAD), nic_read(NIC_IRQ_STATUS));
        failures++;
    }
    if (!wait_done(rx) || rx[0].status != (NIC_DESC_DD | FRAME_BYTES)) {
        uart_printf("PA NIC RX failed: status=%x head=%u irq=%x\n",
                    rx[0].status, nic_read(NIC_RX_HEAD), nic_read(NIC_IRQ_STATUS));
        failures++;
    }
    __asm__ volatile("fence r, r" ::: "memory");
    for (unsigned i = 0; i < FRAME_BYTES; ++i) {
        if (rx_buf[i] != frame_byte(i)) {
            uart_printf("PA NIC byte %u got %x want %x\n", i, rx_buf[i], frame_byte(i));
            failures++;
            break;
        }
    }
    if (*sentinel != 0x554433221100ffeeull ||
        nic_read_counter(NIC_CNT_TX_FRAMES) != 1u ||
        nic_read_counter(NIC_CNT_RX_FRAMES) != 1u) {
        uart_printf("PA NIC sentinel/counters failed: tx=%u rx=%u\n",
                    (unsigned) nic_read_counter(NIC_CNT_TX_FRAMES),
                    (unsigned) nic_read_counter(NIC_CNT_RX_FRAMES));
        failures++;
    }
    uart_printf(failures ? "<<FAIL>>\n" : "<<PASS>>\n");
    for (;;) {
    }
}
