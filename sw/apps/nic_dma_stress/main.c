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
 * Two rounds of 15 queued loopback frames each compete with a 4 KiB
 * coherent DMA copy, in single-beat and burst modes. Check overlap at the
 * first received frame, every frame byte, the MAC overflow counter, DMA
 * completion and every copied word.
 */
#include <stdint.h>

#include "dma_engine.h"
#include "nic.h"
#include "uart.h"

#define WAIT_READY 4000u
#define WAIT_CARRIER 12000u
#define WAIT_LINK_TRANSCEIVER 20000000u
#define WAIT_DD 40000u
#define WAIT_DMA 200000u
#define ENABLE_TRIES_TRANSCEIVER 3u

#define DDR_SCRATCH 0x81800000u
#define RX_LOG2 4u
#define TX_LOG2 4u
#define ENTRIES 16u
#define FRAMES 15u
#define ROUNDS 2u
#define BUF_STRIDE 0x800u
#define RX_BUF_LEN 1600u
#define RX_BUF(i) (DDR_SCRATCH + 0x10000u + BUF_STRIDE * (i))
#define TX_BUF(i) (DDR_SCRATCH + 0x20000u + BUF_STRIDE * (i))
#define DMA_SRC 0x82000000u
#define DMA_DST 0x82200000u
#define DMA_LEN 0x1000u
#define DMA_TOTAL_LEN (ROUNDS * DMA_LEN)

static volatile struct nic_desc *const rx_ring = (volatile struct nic_desc *) DDR_SCRATCH;
static volatile struct nic_desc *const tx_ring =
    (volatile struct nic_desc *) (DDR_SCRATCH + 0x1000u);
static const uint8_t station[6] = {0x02, 0x11, 0x22, 0x33, 0x44, 0x55};
static uint32_t g_rx_posted, g_rx_reaped, g_tx_posted;
static int g_transceiver;
static uint32_t g_loopback_ctrl;
static uint32_t g_wait_link_ready, g_wait_carrier, g_enable_tries;

static int wait_status(uint32_t mask, uint32_t value, uint32_t budget)
{
    while (budget--) {
        if ((nic_read(NIC_STATUS) & mask) == value)
            return 1;
    }
    return 0;
}

static int wait_dd(volatile struct nic_desc *d)
{
    for (uint32_t n = 0; n < WAIT_DD; n++) {
        if (d->status & NIC_DESC_DD)
            return 1;
    }
    return 0;
}

static void post_rx(uint32_t n)
{
    for (uint32_t k = 0; k < n; k++) {
        uint32_t i = g_rx_posted % ENTRIES;
        rx_ring[i].addr = RX_BUF(g_rx_posted % (ROUNDS * FRAMES)) + (g_rx_posted % 4u) * 8u;
        rx_ring[i].len = RX_BUF_LEN;
        rx_ring[i].status = 0;
        g_rx_posted++;
    }
    __asm__ volatile("fence w, o" ::: "memory");
    nic_write(NIC_RX_TAIL, g_rx_posted % ENTRIES);
}

static uint32_t frame_len(uint32_t n)
{
    return (n % FRAMES) % 3u == 0 ? 1518u : 64u;
}

static void select_loopback(void)
{
    uint32_t phy_status = nic_read(NIC_PHY_STATUS);
    if (phy_status & NIC_PHY_STATUS_CLK_SHARED) {
        g_transceiver = 0;
        g_loopback_ctrl = NIC_PHY_CTRL_MAC_LOOPBACK;
        g_wait_link_ready = WAIT_READY;
        g_wait_carrier = WAIT_CARRIER;
        g_enable_tries = 1u;
    } else {
        g_transceiver = 1;
        g_loopback_ctrl = NIC_PHY_CTRL_PMA_LOOPBACK;
        g_wait_link_ready = WAIT_LINK_TRANSCEIVER;
        g_wait_carrier = WAIT_LINK_TRANSCEIVER;
        g_enable_tries = ENABLE_TRIES_TRANSCEIVER;
    }
    uart_printf("PHY_STATUS %x: PHY_CTRL loopback %x\n", phy_status, g_loopback_ctrl);
}

/* A PMA loopback change can restart the receiver after enable, dropping
 * READY. The NIC disables that direction but preserves ring registers and
 * HEAD. CARRIER stays down through the restart and returns after READY.
 * Re-enable ready directions, preserving PROMISC because non-RESET CTRL
 * writes reload it. Return 0 unless both directions are enabled. */
static int reenable_after_ready_loss(void)
{
    const uint32_t enables = NIC_CTRL_RX_EN | NIC_CTRL_TX_EN;
    uint32_t ctrl = nic_read(NIC_CTRL);
    uint32_t status = nic_read(NIC_STATUS);
    uint32_t lost = 0;
    if (!(ctrl & NIC_CTRL_RX_EN) && (status & NIC_STATUS_RX_READY))
        lost |= NIC_CTRL_RX_EN;
    if (!(ctrl & NIC_CTRL_TX_EN) && (status & NIC_STATUS_TX_READY))
        lost |= NIC_CTRL_TX_EN;
    if (lost) {
        nic_write(NIC_CTRL, enables | (ctrl & NIC_CTRL_PROMISC));
        ctrl = nic_read(NIC_CTRL);
        uart_printf("re-enabled %x after a READY loss: CTRL %x\n", lost, ctrl);
    }
    if ((ctrl & enables) != enables) {
        uart_printf("enable lost: CTRL %x STATUS %x\n", ctrl, nic_read(NIC_STATUS));
        return 0;
    }
    return 1;
}

static int bringup(void)
{
    if (nic_read(NIC_ID) != NIC_ID_VALUE) {
        uart_printf("ID %x\n", nic_read(NIC_ID));
        return 0;
    }
    uart_printf("STATUS %x LINK %x\n", nic_read(NIC_STATUS), nic_read(NIC_LINK));
    if (!wait_status(NIC_STATUS_RX_READY | NIC_STATUS_TX_READY,
                     NIC_STATUS_RX_READY | NIC_STATUS_TX_READY,
                     g_wait_link_ready)) {
        uart_printf("not READY: STATUS %x LINK %x\n", nic_read(NIC_STATUS), nic_read(NIC_LINK));
        return 0;
    }
    nic_write(NIC_PHY_CTRL, g_loopback_ctrl);
    nic_write(NIC_CTRL, NIC_CTRL_RESET);
    if (!wait_status(NIC_STATUS_RESET_BUSY, 0, WAIT_READY)) {
        uart_printf("RESET stuck: %x\n", nic_read(NIC_STATUS));
        return 0;
    }
    if (!wait_status(NIC_STATUS_RX_READY | NIC_STATUS_TX_READY,
                     NIC_STATUS_RX_READY | NIC_STATUS_TX_READY,
                     g_wait_link_ready)) {
        uart_printf("not READY after RESET: %x\n", nic_read(NIC_STATUS));
        return 0;
    }
    nic_write(NIC_MAC_LO,
              (uint32_t) station[0] | ((uint32_t) station[1] << 8) | ((uint32_t) station[2] << 16) |
                  ((uint32_t) station[3] << 24));
    nic_write(NIC_MAC_HI, (uint32_t) station[4] | ((uint32_t) station[5] << 8));
    nic_write(NIC_RX_BASE, (uint32_t) (uintptr_t) rx_ring);
    nic_write(NIC_RX_SIZE, RX_LOG2);
    nic_write(NIC_TX_BASE, (uint32_t) (uintptr_t) tx_ring);
    nic_write(NIC_TX_SIZE, TX_LOG2);
    g_rx_posted = 0;
    g_rx_reaped = 0;
    g_tx_posted = 0;
    post_rx(ENTRIES - 1u);
    nic_write(NIC_RX_ITR, 0);
    nic_write(NIC_TX_ITR, 0);
    nic_write(NIC_IRQ_STATUS, NIC_IRQ_RX | NIC_IRQ_TX | NIC_IRQ_RX_DROP | NIC_IRQ_DESC_ERR);
    /* Enable requires READY and a valid ring. A PMA loopback restart can
     * drop READY after the wait above; retry when READY returns, up to
     * g_enable_tries writes. A shared MAC clock gets one attempt. */
    const uint32_t enables = NIC_CTRL_RX_EN | NIC_CTRL_TX_EN;
    const uint32_t ready = NIC_STATUS_RX_READY | NIC_STATUS_TX_READY;
    nic_write(NIC_CTRL, enables);
    for (uint32_t tries = 1u; (nic_read(NIC_CTRL) & enables) != enables; tries++) {
        if (tries >= g_enable_tries || !wait_status(ready, ready, g_wait_link_ready)) {
            uart_printf(
                "enable refused: CTRL %x STATUS %x\n", nic_read(NIC_CTRL), nic_read(NIC_STATUS));
            return 0;
        }
        nic_write(NIC_CTRL, enables);
    }
    uint32_t budget = g_wait_carrier;
    while (budget-- && !(nic_read(NIC_LINK) & NIC_LINK_CARRIER))
        ;
    if (!(nic_read(NIC_LINK) & NIC_LINK_CARRIER)) {
        uart_printf("no carrier: LINK %x\n", nic_read(NIC_LINK));
        return 0;
    }
    if (g_transceiver && !reenable_after_ready_loss())
        return 0;
    return 1;
}

static uint64_t dma_word(uint32_t n, uint32_t pass)
{
    return UINT64_C(0xa55a123400000000) | ((uint64_t) pass << 24) | n;
}

static int test_stress(uint32_t mode, uint32_t pass, const char *name)
{
    volatile uint64_t *src = (volatile uint64_t *) DMA_SRC;
    volatile uint64_t *dst = (volatile uint64_t *) DMA_DST;
    for (uint32_t n = 0; n < DMA_TOTAL_LEN / 8u; n++)
        src[n] = dma_word(n, pass);
    for (uint32_t n = 0; n < DMA_TOTAL_LEN / 8u; n++)
        dst[n] = ~dma_word(n, pass);
    /* Dword-aligned buffers allow full comparisons without byte loops. */
    for (uint32_t n = 0; n < ROUNDS * FRAMES; n++) {
        uint64_t *buf = (uint64_t *) (uintptr_t) (TX_BUF(n) + (n % 4u) * 8u);
        uint32_t words = frame_len(n) / 8u;
        for (uint32_t w = 0; w < words; w++)
            buf[w] =
                UINT64_C(0x0706050403020100) ^ ((uint64_t) pass << 56) ^ ((uint64_t) n << 48) ^ w;
        buf[0] = (buf[0] & UINT64_C(0xffff000000000000)) | UINT64_C(0x554433221102);
        uint8_t *tail = (uint8_t *) &buf[words];
        for (uint32_t b = 0; b < frame_len(n) % 8u; b++)
            tail[b] = (uint8_t) (pass + n + b);
    }
    uint32_t first_rx = g_rx_reaped;
    uint64_t base_rx = nic_read_counter(NIC_CNT_RX_FRAMES);
    uint64_t base_tx = nic_read_counter(NIC_CNT_TX_FRAMES);
    uint32_t overlap_lines[ROUNDS];
    for (uint32_t round = 0; round < ROUNDS; round++) {
        dma_engine_ack();
        dma_engine_setup(
            DMA_SRC + round * DMA_LEN, DMA_DST + round * DMA_LEN, DMA_LEN, mode, 0, 0, 0);
        if (g_rx_posted - g_rx_reaped < FRAMES)
            post_rx(FRAMES - (g_rx_posted - g_rx_reaped));
        uint32_t first_tx = g_tx_posted;
        for (uint32_t k = 0; k < FRAMES; k++) {
            uint32_t n = round * FRAMES + k;
            uint32_t i = g_tx_posted++ % ENTRIES;
            tx_ring[i].addr = TX_BUF(n) + (n % 4u) * 8u;
            tx_ring[i].len = frame_len(n) | NIC_TX_SOP | NIC_TX_EOP;
            tx_ring[i].status = 0;
        }
        __asm__ volatile("fence w, o" ::: "memory");
        /* One doorbell exposes all 15 frames to the transmitter. */
        nic_write(NIC_TX_TAIL, g_tx_posted % ENTRIES);
        dma_engine_start();
        for (uint32_t k = 0; k < FRAMES; k++) {
            uint32_t n = round * FRAMES + k;
            uint32_t i = g_rx_reaped++ % ENTRIES;
            if (!wait_dd(&rx_ring[i]) || rx_ring[i].status != (NIC_DESC_DD | frame_len(n))) {
                uart_printf("%s: RX frame %u status %x\n", name, n, rx_ring[i].status);
                return 0;
            }
            if (k == 0) {
                if (!(dma_engine_status() & DMA_ENGINE_STATUS_BUSY)) {
                    uart_printf("%s: DMA idle at first RX in round %u\n", name, round);
                    return 0;
                }
                overlap_lines[round] = dma_engine_read(DMA_ENGINE_LINES);
            }
            uint32_t tx = (first_tx + k) % ENTRIES;
            if (!wait_dd(&tx_ring[tx]) || tx_ring[tx].status != NIC_DESC_DD) {
                uart_printf("%s: TX frame %u status %x\n", name, n, tx_ring[tx].status);
                return 0;
            }
        }
        uint32_t budget = WAIT_DMA;
        uint32_t status;
        do {
            status = dma_engine_status();
        } while ((status & DMA_ENGINE_STATUS_BUSY) && --budget);
        if (status != DMA_ENGINE_STATUS_DONE ||
            dma_engine_read(DMA_ENGINE_LINES) != DMA_LEN / 32u) {
            uart_printf(
                "%s: DMA status %x lines %u\n", name, status, dma_engine_read(DMA_ENGINE_LINES));
            return 0;
        }
    }
    __asm__ volatile("fence i, r" ::: "memory");
    for (uint32_t n = 0; n < DMA_TOTAL_LEN / 8u; n++) {
        if (dst[n] != dma_word(n, pass)) {
            uart_printf("%s: DMA word %u mismatch\n", name, n);
            return 0;
        }
    }
    for (uint32_t n = 0; n < ROUNDS * FRAMES; n++) {
        const volatile uint64_t *rx_buf =
            (const volatile uint64_t *) (uintptr_t) (RX_BUF(n) + ((first_rx + n) % 4u) * 8u);
        const uint64_t *tx_buf = (const uint64_t *) (uintptr_t) (TX_BUF(n) + (n % 4u) * 8u);
        uint32_t words = frame_len(n) / 8u;
        for (uint32_t w = 0; w < words; w++) {
            if (rx_buf[w] != tx_buf[w]) {
                uart_printf("%s: RX frame %u word %u mismatch\n", name, n, w);
                return 0;
            }
        }
        const volatile uint8_t *rx_tail = (const volatile uint8_t *) &rx_buf[words];
        const uint8_t *tx_tail = (const uint8_t *) &tx_buf[words];
        for (uint32_t b = 0; b < frame_len(n) % 8u; b++) {
            if (rx_tail[b] != tx_tail[b]) {
                uart_printf("%s: RX frame %u tail byte %u mismatch\n", name, n, b);
                return 0;
            }
        }
    }
    uint64_t rx = nic_read_counter(NIC_CNT_RX_FRAMES) - base_rx;
    uint64_t tx = nic_read_counter(NIC_CNT_TX_FRAMES) - base_tx;
    uint64_t overflow = nic_read_counter(NIC_CNT_RX_MAC_OVERFLOW);
    if (rx != ROUNDS * FRAMES || tx != ROUNDS * FRAMES || overflow != 0) {
        uart_printf("%s: RX %u TX %u overflow %u\n",
                    name,
                    (uint32_t) rx,
                    (uint32_t) tx,
                    (uint32_t) overflow);
        return 0;
    }
    dma_engine_ack();
    for (uint32_t round = 0; round < ROUNDS; round++)
        uart_printf("%s round %u: first RX at DMA line %u/%u\n",
                    name,
                    round,
                    overlap_lines[round],
                    DMA_LEN / 32u);
    uart_printf("%s OK: %u frames, MAC RX overflow 0, DMA %u x %u KiB checked\n",
                name,
                ROUNDS * FRAMES,
                ROUNDS,
                DMA_LEN / 1024u);
    return 1;
}

int main(void)
{
    uart_printf("nic_dma_stress\n");
    select_loopback();
    if (!bringup() || !test_stress(DMA_ENGINE_MODE_COPY, 1u, "copy") ||
        !test_stress(DMA_ENGINE_MODE_COPY | DMA_ENGINE_MODE_BURST, 2u, "burst")) {
        uart_printf("<<FAIL>>\n");
        return 1;
    }
    uart_printf("<<PASS>>\n");
    return 0;
}
