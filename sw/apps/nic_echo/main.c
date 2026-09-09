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
 * NIC echo (hw/rtl/peripherals/nic, sw/lib/include/nic.h).
 *
 * What a real link looks like to the NIC: the bench's wire-side peer
 * (verif/cocotb_tests/test_real_program.py) sends frames into the raw RX
 * interface and decodes the raw TX interface; this program echoes every
 * frame it receives, interrupt-driven with moderation, reposting RX
 * descriptors as it goes. The peer's plan (a fixed count of frames landing
 * in the ring, of which two are truncated by the buffer length, plus two
 * frames for another station that the filter drops) is known here, so the
 * counters are checked at the end. Prints "echo ready" when the peer may
 * start, then <<PASS>> or <<FAIL>>.
 */
#include <stdint.h>

#include "csr.h"
#include "nic.h"
#include "trap.h"
#include "uart.h"

#define REG32(a) (*(volatile uint32_t *) (uintptr_t) (a))
#define PLIC_BASE 0x44000000ul
#define PLIC_PRIO(s) REG32(PLIC_BASE + 4ul * (s))
#define PLIC_EN_M REG32(PLIC_BASE + 0x2000ul)
#define PLIC_THR_M REG32(PLIC_BASE + 0x200000ul)
#define PLIC_CLAIM_M REG32(PLIC_BASE + 0x200004ul)

/* The peer's plan (verif/cocotb_tests/test_real_program.py, NicEchoPeer). */
#define EXPECT_RX 24u      /* frames that land in the ring */
#define EXPECT_TRUNC 2u    /* of which longer than the buffer */
#define EXPECT_FILTERED 2u /* frames for another station */
#define EXPECT_TX (EXPECT_RX - EXPECT_TRUNC)

#define DDR_SCRATCH 0x81900000u
#define RX_LOG2 3u /* 8 entries: the ring wraps three times */
#define TX_LOG2 4u
#define RX_ENTRIES (1u << RX_LOG2)
#define TX_ENTRIES (1u << TX_LOG2)
#define RX_BUF_LEN 2048u /* a jumbo frame truncates */
#define BUF_STRIDE 0x1000u
static volatile struct nic_desc *const rx_ring = (volatile struct nic_desc *) (DDR_SCRATCH);
static volatile struct nic_desc *const tx_ring =
    (volatile struct nic_desc *) (DDR_SCRATCH + 0x100u);
#define RX_BUF(i) (DDR_SCRATCH + 0x10000u + BUF_STRIDE * (i) + 2u) /* the driver's headroom */
#define TX_BUF(i) (DDR_SCRATCH + 0x20000u + BUF_STRIDE * (i) + 2u)

static const uint8_t station[6] = {0x02, 0x11, 0x22, 0x33, 0x44, 0x55};

#define WAIT_READY 4000u
#define WAIT_CARRIER 12000u
#define WAIT_IDLE 40000u

static uint32_t g_rx_next, g_rx_posted, g_tx_posted, g_tx_reaped;
static uint32_t g_echoed, g_truncated, g_errors;
volatile uint32_t g_irq_count, g_irq_seen, g_spurious;

static int wait_status(uint32_t mask, uint32_t value, uint32_t budget)
{
    while (budget--) {
        if ((nic_read(NIC_STATUS) & mask) == value)
            return 1;
    }
    return 0;
}

__attribute__((noinline, used)) void nic_irq_c(void)
{
    uint32_t claim = PLIC_CLAIM_M;
    if (claim == NIC_PLIC_SOURCE) {
        uint32_t status = nic_read(NIC_IRQ_STATUS);
        g_irq_seen |= status;
        g_irq_count++;
        nic_write(NIC_IRQ_STATUS, status); /* acknowledge before the scan */
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

static void post_rx_one(uint32_t i)
{
    rx_ring[i].addr = RX_BUF(i);
    rx_ring[i].len = RX_BUF_LEN;
    rx_ring[i].status = 0;
}

static int bringup(void)
{
    if (nic_read(NIC_ID) != NIC_ID_VALUE)
        return 0;
    if (!wait_status(NIC_STATUS_RX_READY | NIC_STATUS_TX_READY,
                     NIC_STATUS_RX_READY | NIC_STATUS_TX_READY,
                     WAIT_READY)) {
        uart_printf("not READY: STATUS %x\n", nic_read(NIC_STATUS));
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
    for (uint32_t i = 0; i < RX_ENTRIES - 1u; i++)
        post_rx_one(i);
    g_rx_posted = RX_ENTRIES - 1u;
    g_rx_next = 0;
    g_tx_posted = 0;
    g_tx_reaped = 0;
    __asm__ volatile("fence w, o" ::: "memory"); /* memory writes before the I/O doorbell */
    nic_write(NIC_RX_TAIL, g_rx_posted % RX_ENTRIES);
    /* Moderation: up to four completions or 40 ticks of 30 cycles. */
    nic_write(NIC_TICK, 30);
    nic_write(NIC_RX_ITR, NIC_ITR(40, 4));
    nic_write(NIC_TX_ITR, NIC_ITR(40, 8));
    nic_write(NIC_IRQ_STATUS, NIC_IRQ_ALL);
    nic_write(NIC_IRQ_MASK, NIC_IRQ_RX | NIC_IRQ_TX | NIC_IRQ_DESC_ERR);
    set_trap_handler(&nic_irq_entry);
    PLIC_PRIO(NIC_PLIC_SOURCE) = 1;
    PLIC_THR_M = 0;
    PLIC_EN_M = 1u << NIC_PLIC_SOURCE;
    enable_external_interrupt();
    enable_interrupts();
    nic_write(NIC_CTRL, NIC_CTRL_RX_EN | NIC_CTRL_TX_EN);
    if ((nic_read(NIC_CTRL) & (NIC_CTRL_RX_EN | NIC_CTRL_TX_EN)) !=
        (NIC_CTRL_RX_EN | NIC_CTRL_TX_EN)) {
        uart_printf("enable refused: STATUS %x\n", nic_read(NIC_STATUS));
        return 0;
    }
    uint32_t budget = WAIT_CARRIER;
    while (budget-- && !(nic_read(NIC_LINK) & NIC_LINK_CARRIER))
        ;
    if (!(nic_read(NIC_LINK) & NIC_LINK_CARRIER)) {
        uart_printf("no carrier: LINK %x\n", nic_read(NIC_LINK));
        return 0;
    }
    return 1;
}

static void reap_tx(void)
{
    while (g_tx_reaped < g_tx_posted) {
        uint32_t j = g_tx_reaped % TX_ENTRIES;
        uint32_t s = tx_ring[j].status;
        if (!(s & NIC_DESC_DD))
            break;
        if (s & (NIC_DESC_ERR | NIC_DESC_ABORT)) {
            uart_printf("tx %u: status %x len %x\n", g_tx_reaped, s, tx_ring[j].len);
            g_errors++;
        }
        g_tx_reaped++;
    }
}

static void echo(uint32_t rx_index, uint32_t len)
{
    /* A free TX descriptor: at most TX_ENTRIES - 1 posted. */
    while (g_tx_posted - g_tx_reaped >= TX_ENTRIES - 1u)
        reap_tx();
    uint32_t j = g_tx_posted % TX_ENTRIES;
    volatile uint8_t *src = (volatile uint8_t *) (uintptr_t) rx_ring[rx_index].addr;
    volatile uint8_t *dst = (volatile uint8_t *) (uintptr_t) TX_BUF(j);
    for (uint32_t b = 0; b < len; b++)
        dst[b] = src[b];
    tx_ring[j].addr = TX_BUF(j);
    tx_ring[j].len = len | NIC_TX_SOP | NIC_TX_EOP;
    tx_ring[j].status = 0;
    g_tx_posted++;
    __asm__ volatile("fence w, o" ::: "memory"); /* memory writes before the I/O doorbell */
    nic_write(NIC_TX_TAIL, g_tx_posted % TX_ENTRIES);
}

/* Handle every completed RX descriptor; returns how many. */
static uint32_t scan_rx(void)
{
    uint32_t n = 0;
    for (;;) {
        uint32_t i = g_rx_next % RX_ENTRIES;
        uint32_t s = rx_ring[i].status;
        if (!(s & NIC_DESC_DD))
            break;
        __asm__ volatile("fence r, r" ::: "memory"); /* DD before the data */
        uint32_t len = s & NIC_DESC_LEN_MASK;
        if (s & (NIC_DESC_ERR | NIC_DESC_ABORT)) {
            uart_printf("rx %u: status %x addr %x len %x head %u\n",
                        g_rx_next,
                        s,
                        rx_ring[i].addr,
                        rx_ring[i].len,
                        nic_read(NIC_RX_HEAD));
            g_errors++;
        } else if (s & NIC_DESC_TRUNC) {
            g_truncated++;
        } else {
            echo(i, len);
            g_echoed++;
        }
        /* Post the producer's slot (the one freed a ring ago, its buffer
         * long echoed), never the slot just consumed: the ring stays
         * ENTRIES - 1 deep and the slot behind TAIL is always written. */
        g_rx_next++;
        post_rx_one(g_rx_posted % RX_ENTRIES);
        g_rx_posted++;
        __asm__ volatile("fence w, o" ::: "memory"); /* memory writes before the I/O doorbell */
        nic_write(NIC_RX_TAIL, g_rx_posted % RX_ENTRIES);
        n++;
    }
    return n;
}

int main(void)
{
    uart_printf("nic_echo\n");
    if (!bringup()) {
        uart_printf("bringup FAIL\n<<FAIL>>\n");
        return 1;
    }
    uart_printf("echo ready\n");
    uint32_t handled = 0;
    uint32_t idle_polls = 0;
    while (handled < EXPECT_RX) {
        uint32_t n = scan_rx();
        reap_tx();
        handled += n;
        if (n == 0) {
            /* Sleep until the NIC interrupts (a completion may already be
             * pending: the level stays up until acknowledged, so wfi returns
             * at once). */
            wfi();
            if (++idle_polls > 2000000u) {
                uart_printf("stalled: handled %u status %x irq %x\n",
                            handled,
                            nic_read(NIC_STATUS),
                            nic_read(NIC_IRQ_STATUS));
                uart_printf("<<FAIL>>\n");
                return 1;
            }
        }
    }
    /* Every echo has left through the TX ring. */
    uint32_t budget = WAIT_IDLE;
    while (budget-- && g_tx_reaped < g_tx_posted)
        reap_tx();
    disable_interrupts();
    PLIC_EN_M = 0;
    int ok = 1;
    if (g_echoed != EXPECT_TX || g_truncated != EXPECT_TRUNC || g_errors != 0 ||
        g_tx_reaped != g_tx_posted) {
        uart_printf("echoed %u truncated %u errors %u tx %u/%u\n",
                    g_echoed,
                    g_truncated,
                    g_errors,
                    g_tx_reaped,
                    g_tx_posted);
        ok = 0;
    }
    uint32_t rx_frames = (uint32_t) nic_read_counter(NIC_CNT_RX_FRAMES);
    uint32_t rx_trunc = (uint32_t) nic_read_counter(NIC_CNT_RX_TRUNCATED);
    uint32_t rx_filtered = (uint32_t) nic_read_counter(NIC_CNT_RX_FILTERED);
    uint32_t tx_frames = (uint32_t) nic_read_counter(NIC_CNT_TX_FRAMES);
    if (rx_frames != EXPECT_TX || rx_trunc != EXPECT_TRUNC || rx_filtered != EXPECT_FILTERED ||
        tx_frames != EXPECT_TX || nic_read_counter(NIC_CNT_RX_DESC_ERR) != 0 ||
        nic_read_counter(NIC_CNT_TX_DESC_ERR) != 0) {
        uart_printf("counters: rx %u trunc %u filtered %u tx %u desc_err %u aborted %u\n",
                    rx_frames,
                    rx_trunc,
                    rx_filtered,
                    tx_frames,
                    (uint32_t) nic_read_counter(NIC_CNT_RX_DESC_ERR),
                    (uint32_t) nic_read_counter(NIC_CNT_RX_ABORTED));
        ok = 0;
    }
    if (!(g_irq_seen & NIC_IRQ_RX) || g_spurious != 0) {
        uart_printf("irq: seen %x count %u spurious %u\n", g_irq_seen, g_irq_count, g_spurious);
        ok = 0;
    }
    uart_printf("irqs %u\n", g_irq_count);
    uart_printf(ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    return 0;
}
