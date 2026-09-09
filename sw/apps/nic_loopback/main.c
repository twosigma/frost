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
 * NIC loopback test (hw/rtl/peripherals/nic, sw/lib/include/nic.h).
 *
 * Drives the NIC the way the Linux driver will: bring-up through READY, the
 * raw loopback selected through a RESET, station address, rings in cached
 * DDR, descriptors posted with a TAIL doorbell, completions read from the
 * descriptors (DD), counters, the completion and link interrupts, the
 * moderation registers, a RESET in the middle of traffic, and the filter.
 * Frames go out through TX, around the loopback inside the MAC wrapper and
 * back into RX buffers, where every byte is compared.
 *
 * Prints <<PASS>> or <<FAIL>>. Runs in both memory tiers: rings and buffers
 * live at fixed DDR addresses above every image.
 */
#include <stdint.h>

#include "csr.h"
#include "nic.h"
#include "trap.h"
#include "uart.h"

#ifndef MCAUSE_INTERRUPT_BIT
#define MCAUSE_INTERRUPT_BIT (1ul << 63)
#endif

/* Polling budgets in loop iterations (an MMIO read each, tens of cycles):
 * sized so a failed wait reports inside the simulation's cycle budget while
 * leaving the hardware (300 MHz) milliseconds. */
#define WAIT_READY 4000u
#define WAIT_CARRIER 12000u
#define WAIT_DD 40000u
#define WAIT_IRQ 4000u

#define REG32(a) (*(volatile uint32_t *) (uintptr_t) (a))
#define PLIC_BASE 0x44000000ul
#define PLIC_PRIO(s) REG32(PLIC_BASE + 4ul * (s))
#define PLIC_EN_M REG32(PLIC_BASE + 0x2000ul)
#define PLIC_THR_M REG32(PLIC_BASE + 0x200000ul)
#define PLIC_CLAIM_M REG32(PLIC_BASE + 0x200004ul)

/* Rings and buffers 24 MiB into cached DDR, above every image. */
#define DDR_SCRATCH 0x81800000u
#define RX_LOG2 4u
#define TX_LOG2 4u
#define ENTRIES 16u
#define BUF_STRIDE 0x4000u /* 16 KiB per buffer: a jumbo frame with room */
#define RX_BUF_LEN 9216u
static volatile struct nic_desc *const rx_ring = (volatile struct nic_desc *) (DDR_SCRATCH);
static volatile struct nic_desc *const tx_ring =
    (volatile struct nic_desc *) (DDR_SCRATCH + 0x1000u);
#define RX_BUF(i) (DDR_SCRATCH + 0x10000u + BUF_STRIDE * (i))
#define TX_BUF(i) (DDR_SCRATCH + 0x50000u + BUF_STRIDE * (i))

static const uint8_t station[6] = {0x02, 0x11, 0x22, 0x33, 0x44, 0x55};
static const uint8_t other[6] = {0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE};

static uint32_t g_failures;
static uint32_t g_rx_posted, g_rx_reaped, g_tx_posted;
volatile uint32_t g_irq_count;
volatile uint32_t g_irq_seen; /* IRQ_STATUS bits seen by the handler */
volatile uint32_t g_spurious;

static void check(const char *name, int ok)
{
    if (ok) {
        uart_printf("%s OK\n", name);
    } else {
        uart_printf("%s FAIL\n", name);
        g_failures++;
    }
}

static int wait_status(uint32_t mask, uint32_t value, uint32_t budget)
{
    while (budget--) {
        if ((nic_read(NIC_STATUS) & mask) == value)
            return 1;
    }
    return 0;
}

static int wait_dd(volatile struct nic_desc *d, uint32_t budget)
{
    while (budget--) {
        if (d->status & NIC_DESC_DD)
            return 1;
    }
    return 0;
}

static void post_rx(uint32_t n)
{
    for (uint32_t k = 0; k < n; k++) {
        uint32_t i = g_rx_posted % ENTRIES;
        rx_ring[i].addr = RX_BUF(i) + (g_rx_posted % 7u) * 9u; /* odd offsets */
        rx_ring[i].len = RX_BUF_LEN;
        rx_ring[i].status = 0;
        g_rx_posted++;
    }
    __asm__ volatile("fence w, o" ::: "memory"); /* the descriptors before the doorbell */
    nic_write(NIC_RX_TAIL, g_rx_posted % ENTRIES);
}

static void fill_frame(uint8_t *buf, uint32_t len, const uint8_t *da, uint32_t seed)
{
    for (uint32_t i = 0; i < 6 && i < len; i++)
        buf[i] = da[i];
    for (uint32_t i = 6; i < len; i++)
        buf[i] = (uint8_t) (seed * 31u + i * 7u + (i >> 8));
}

static uint32_t send_tx(uint32_t len, const uint8_t *da, uint32_t seed)
{
    uint32_t i = g_tx_posted % ENTRIES;
    uint32_t addr = TX_BUF(i) + (g_tx_posted % 5u) * 3u;
    fill_frame((uint8_t *) (uintptr_t) addr, len, da, seed);
    tx_ring[i].addr = addr;
    tx_ring[i].len = len | NIC_TX_SOP | NIC_TX_EOP;
    tx_ring[i].status = 0;
    g_tx_posted++;
    __asm__ volatile("fence w, o" ::: "memory"); /* memory writes before the I/O doorbell */
    nic_write(NIC_TX_TAIL, g_tx_posted % ENTRIES);
    return i;
}

/* The RX descriptor g_rx_reaped holds the frame sent as (len, da, seed)? */
static int reap_rx(uint32_t len, const uint8_t *da, uint32_t seed, const char *what)
{
    uint32_t i = g_rx_reaped % ENTRIES;
    g_rx_reaped++;
    if (!wait_dd(&rx_ring[i], WAIT_DD)) {
        uart_printf("%s: RX descriptor %u never completed (status %x head %u)\n",
                    what,
                    i,
                    rx_ring[i].status,
                    nic_read(NIC_RX_HEAD));
        return 0;
    }
    uint32_t expected_len = len < 60u ? 60u : len;
    uint32_t status = rx_ring[i].status;
    if (status != (NIC_DESC_DD | expected_len)) {
        uart_printf("%s: RX status %x, expected %x\n", what, status, NIC_DESC_DD | expected_len);
        return 0;
    }
    __asm__ volatile("fence r, r" ::: "memory"); /* DD before the data */
    const volatile uint8_t *buf = (const volatile uint8_t *) (uintptr_t) rx_ring[i].addr;
    uint8_t want[8];
    for (uint32_t b = 0; b < expected_len; b++) {
        uint8_t w;
        if (b < len) {
            fill_frame(want, 1, da, seed); /* unused: recompute below */
            w = b < 6 ? da[b] : (uint8_t) (seed * 31u + b * 7u + (b >> 8));
        } else {
            w = 0; /* the MAC pads with zeros */
        }
        if (buf[b] != w) {
            uart_printf("%s: byte %u got %x want %x\n", what, b, buf[b], w);
            return 0;
        }
    }
    return 1;
}

static int bringup(int loopback)
{
    if (nic_read(NIC_ID) != NIC_ID_VALUE) {
        uart_printf("ID %x\n", nic_read(NIC_ID));
        return 0;
    }
    uart_printf("STATUS %x LINK %x\n", nic_read(NIC_STATUS), nic_read(NIC_LINK));
    if (!wait_status(NIC_STATUS_RX_READY | NIC_STATUS_TX_READY,
                     NIC_STATUS_RX_READY | NIC_STATUS_TX_READY,
                     WAIT_READY)) {
        uart_printf("not READY: STATUS %x LINK %x\n", nic_read(NIC_STATUS), nic_read(NIC_LINK));
        return 0;
    }
    if (loopback) {
        nic_write(NIC_PHY_CTRL, NIC_PHY_CTRL_MAC_LOOPBACK);
        nic_write(NIC_CTRL, NIC_CTRL_RESET);
        if (!wait_status(NIC_STATUS_RESET_BUSY, 0, WAIT_READY)) {
            uart_printf("RESET stuck: %x\n", nic_read(NIC_STATUS));
            return 0;
        }
        if (!wait_status(NIC_STATUS_RX_READY | NIC_STATUS_TX_READY,
                         NIC_STATUS_RX_READY | NIC_STATUS_TX_READY,
                         WAIT_READY)) {
            uart_printf("not READY after RESET: %x\n", nic_read(NIC_STATUS));
            return 0;
        }
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
    nic_write(NIC_CTRL, NIC_CTRL_RX_EN | NIC_CTRL_TX_EN);
    if ((nic_read(NIC_CTRL) & (NIC_CTRL_RX_EN | NIC_CTRL_TX_EN)) !=
        (NIC_CTRL_RX_EN | NIC_CTRL_TX_EN)) {
        uart_printf(
            "enable refused: CTRL %x STATUS %x\n", nic_read(NIC_CTRL), nic_read(NIC_STATUS));
        return 0;
    }
    if (loopback) {
        uint32_t budget = WAIT_CARRIER;
        while (budget-- && !(nic_read(NIC_LINK) & NIC_LINK_CARRIER))
            ;
        if (!(nic_read(NIC_LINK) & NIC_LINK_CARRIER)) {
            uart_printf("no carrier: LINK %x\n", nic_read(NIC_LINK));
            return 0;
        }
    }
    return 1;
}

/* ---- frames of every shape around the loopback ---- */
static void test_frames(void)
{
    static const uint32_t lengths[] = {60u, 61u, 100u, 1518u, 9000u, 20u, 200u, 64u};
    int ok = 1;
    uint32_t bytes = 0;
    for (uint32_t k = 0; k < sizeof(lengths) / sizeof(lengths[0]); k++) {
        uint64_t t0 = rdmtime();
        uint32_t idx = send_tx(lengths[k], station, k + 1u);
        int got = reap_rx(lengths[k], station, k + 1u, "frames");
        /* The round trip in mtime ticks: doorbell to DD seen, including the
         * software checks; the envelope record in the slice notes reads it. */
        uart_printf("frame %u bytes: %u ticks\n", lengths[k], (uint32_t) (rdmtime() - t0));
        if (!got)
            ok = 0;
        if (!wait_dd(&tx_ring[idx], WAIT_DD) || tx_ring[idx].status != NIC_DESC_DD) {
            uart_printf("frames: TX descriptor %u status %x\n", idx, tx_ring[idx].status);
            ok = 0;
        }
        bytes += lengths[k];
    }
    uint32_t n = sizeof(lengths) / sizeof(lengths[0]);
    if (nic_read_counter(NIC_CNT_TX_FRAMES) != n || nic_read_counter(NIC_CNT_RX_FRAMES) != n ||
        nic_read_counter(NIC_CNT_TX_BYTES) != bytes) {
        uart_printf("frames: counters tx %u rx %u bytes %u\n",
                    (uint32_t) nic_read_counter(NIC_CNT_TX_FRAMES),
                    (uint32_t) nic_read_counter(NIC_CNT_RX_FRAMES),
                    (uint32_t) nic_read_counter(NIC_CNT_TX_BYTES));
        ok = 0;
    }
    if (nic_read(NIC_RX_HEAD) != n || nic_read(NIC_TX_HEAD) != n)
        ok = 0;
    check("frames", ok);
}

/* ---- interrupts: completions and LINK through the PLIC ---- */
__attribute__((noinline, used)) void nic_irq_c(void)
{
    uint32_t claim = PLIC_CLAIM_M;
    if (claim == NIC_PLIC_SOURCE) {
        uint32_t status = nic_read(NIC_IRQ_STATUS);
        g_irq_seen |= status;
        g_irq_count++;
        nic_write(NIC_IRQ_STATUS, status); /* acknowledge before any scan */
        (void) nic_read(NIC_IRQ_STATUS);
    } else {
        g_spurious++;
    }
    PLIC_CLAIM_M = claim;
}

__attribute__((naked, aligned(4))) static void nic_irq_entry(void)
{
    __asm__ volatile("addi sp, sp, -128\n"
                     "sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n"
                     "sd a0, 32(sp)\n sd a1, 40(sp)\n sd a2, 48(sp)\n sd a3, 56(sp)\n"
                     "sd a4, 64(sp)\n sd a5, 72(sp)\n sd a6, 80(sp)\n sd a7, 88(sp)\n"
                     "sd t3, 96(sp)\n sd t4, 104(sp)\n sd t5, 112(sp)\n sd t6, 120(sp)\n"
                     "csrr t0, mcause\n"
                     "bgez t0, 1f\n"
                     "call nic_irq_c\n"
                     "j 2f\n"
                     "1:\n"
                     "la t0, g_spurious\n lw t1, 0(t0)\n addi t1, t1, 1\n sw t1, 0(t0)\n"
                     "csrr t0, mepc\n addi t0, t0, 4\n csrw mepc, t0\n"
                     "2:\n"
                     "ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n"
                     "ld a0, 32(sp)\n ld a1, 40(sp)\n ld a2, 48(sp)\n ld a3, 56(sp)\n"
                     "ld a4, 64(sp)\n ld a5, 72(sp)\n ld a6, 80(sp)\n ld a7, 88(sp)\n"
                     "ld t3, 96(sp)\n ld t4, 104(sp)\n ld t5, 112(sp)\n ld t6, 120(sp)\n"
                     "addi sp, sp, 128\n"
                     "mret\n");
}

static void test_irq(void)
{
    int ok = 1;
    g_irq_count = 0;
    g_irq_seen = 0;
    g_spurious = 0;
    /* The carrier came up during bring-up: the LINK latch is set. */
    if (!(nic_read(NIC_IRQ_STATUS) & NIC_IRQ_LINK)) {
        uart_printf("irq: no LINK latch after bring-up (%x)\n", nic_read(NIC_IRQ_STATUS));
        ok = 0;
    }
    set_trap_handler(&nic_irq_entry);
    PLIC_PRIO(NIC_PLIC_SOURCE) = 1;
    PLIC_THR_M = 0;
    PLIC_EN_M = 1u << NIC_PLIC_SOURCE;
    nic_write(NIC_IRQ_STATUS, NIC_IRQ_ALL);
    nic_write(NIC_IRQ_MASK, NIC_IRQ_RX | NIC_IRQ_TX);
    enable_external_interrupt();
    enable_interrupts();
    send_tx(300u, station, 77u);
    if (!reap_rx(300u, station, 77u, "irq"))
        ok = 0;
    uint32_t budget = WAIT_IRQ;
    while (budget-- && (g_irq_seen & (NIC_IRQ_RX | NIC_IRQ_TX)) != (NIC_IRQ_RX | NIC_IRQ_TX))
        ;
    if ((g_irq_seen & (NIC_IRQ_RX | NIC_IRQ_TX)) != (NIC_IRQ_RX | NIC_IRQ_TX)) {
        uart_printf(
            "irq: seen %x count %u status %x\n", g_irq_seen, g_irq_count, nic_read(NIC_IRQ_STATUS));
        ok = 0;
    }
    /* Moderation: RX raises after three completions, none before. */
    nic_write(NIC_RX_ITR, NIC_ITR(0xFFFF, 3));
    nic_write(NIC_IRQ_MASK, NIC_IRQ_RX);
    g_irq_seen = 0;
    send_tx(80u, station, 1u);
    if (!reap_rx(80u, station, 1u, "moderation"))
        ok = 0;
    send_tx(81u, station, 2u);
    if (!reap_rx(81u, station, 2u, "moderation"))
        ok = 0;
    uint64_t t_wait = rdmtime();
    while (rdmtime() - t_wait < 400u) /* an observable interval, longer than the moderation delay */
        ;
    if (g_irq_seen & NIC_IRQ_RX) {
        uart_printf("moderation: RX raised after two completions\n");
        ok = 0;
    }
    send_tx(82u, station, 3u);
    if (!reap_rx(82u, station, 3u, "moderation"))
        ok = 0;
    budget = WAIT_IRQ;
    while (budget-- && !(g_irq_seen & NIC_IRQ_RX))
        ;
    if (!(g_irq_seen & NIC_IRQ_RX)) {
        uart_printf("moderation: no RX interrupt after three completions\n");
        ok = 0;
    }
    disable_interrupts();
    PLIC_EN_M = 0;
    nic_write(NIC_IRQ_MASK, 0);
    nic_write(NIC_RX_ITR, 0);
    check("irq", ok && g_spurious == 0);
}

/* ---- filter: another station's unicast is dropped, counted, not delivered ---- */
static void test_filter(void)
{
    int ok = 1;
    uint32_t filtered = (uint32_t) nic_read_counter(NIC_CNT_RX_FILTERED);
    uint32_t idx = send_tx(120u, other, 5u);
    if (!wait_dd(&tx_ring[idx], WAIT_DD))
        ok = 0;
    uint32_t budget = WAIT_IRQ;
    while (budget-- && nic_read_counter(NIC_CNT_RX_FILTERED) == filtered)
        ;
    if (nic_read_counter(NIC_CNT_RX_FILTERED) != filtered + 1u) {
        uart_printf("filter: filtered count %u\n",
                    (uint32_t) nic_read_counter(NIC_CNT_RX_FILTERED));
        ok = 0;
    }
    if (!(nic_read(NIC_IRQ_STATUS) & NIC_IRQ_RX_DROP))
        ok = 0;
    nic_write(NIC_IRQ_STATUS, NIC_IRQ_RX_DROP);
    /* The next RX descriptor is untouched: a station frame lands in it. */
    send_tx(130u, station, 6u);
    if (!reap_rx(130u, station, 6u, "filter"))
        ok = 0;
    /* Promiscuous: the other unicast is delivered. */
    nic_write(NIC_CTRL, NIC_CTRL_RX_EN | NIC_CTRL_TX_EN | NIC_CTRL_PROMISC);
    send_tx(140u, other, 8u);
    if (!reap_rx(140u, other, 8u, "promisc"))
        ok = 0;
    nic_write(NIC_CTRL, NIC_CTRL_RX_EN | NIC_CTRL_TX_EN);
    check("filter", ok);
}

/* ---- RESET in the middle of traffic, then a clean restart ---- */
static void test_reset(void)
{
    int ok = 1;
    /* Queue more frames than the RX ring has descriptors (the ring keeps
     * the descriptors the earlier tests left unreaped plus two): the last
     * ones pile up in the FIFO and the MAC while the RX ring runs dry. */
    post_rx(2u);
    uint32_t available = g_rx_posted - g_rx_reaped;
    for (uint32_t k = 0; k < available + 3u; k++)
        send_tx(2000u, station, 40u + k);
    if (!reap_rx(2000u, station, 40u, "reset"))
        ok = 0;
    nic_write(NIC_CTRL, NIC_CTRL_RESET);
    if (!wait_status(NIC_STATUS_RESET_BUSY, 0, WAIT_READY)) {
        uart_printf("reset: busy never cleared: %x\n", nic_read(NIC_STATUS));
        ok = 0;
    }
    if (nic_read(NIC_CTRL) & (NIC_CTRL_RX_EN | NIC_CTRL_TX_EN))
        ok = 0;
    if (nic_read(NIC_RX_BASE) != 0 || nic_read(NIC_TX_HEAD) != 0 ||
        nic_read_counter(NIC_CNT_RX_FRAMES) != 0)
        ok = 0;
    if (nic_read(NIC_PHY_CTRL) != NIC_PHY_CTRL_MAC_LOOPBACK)
        ok = 0;
    /* The LINK interrupt: RESET cleared the mask; enable LINK before the
     * link comes back so the carrier transition raises it. */
    g_irq_seen = 0;
    nic_write(NIC_IRQ_MASK, NIC_IRQ_LINK);
    PLIC_EN_M = 1u << NIC_PLIC_SOURCE;
    enable_interrupts();
    if (!bringup(0)) {
        ok = 0;
    } else {
        if (!(g_irq_seen & NIC_IRQ_LINK)) {
            uart_printf("reset: no LINK interrupt on the carrier transition (seen %x)\n",
                        g_irq_seen);
            ok = 0;
        }
        send_tx(500u, station, 9u);
        if (!reap_rx(500u, station, 9u, "after reset"))
            ok = 0;
    }
    disable_interrupts();
    PLIC_EN_M = 0;
    nic_write(NIC_IRQ_MASK, 0);
    check("reset", ok);
}

int main(void)
{
    uart_printf("nic_loopback\n");
    if (!bringup(1)) {
        uart_printf("bringup FAIL\n<<FAIL>>\n");
        return 1;
    }
    uart_printf("bringup OK\n");
    test_frames();
    test_irq();
    test_filter();
    test_reset();
    if (g_failures == 0) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("%u failures\n<<FAIL>>\n", g_failures);
    }
    return 0;
}
