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
 * NIC throughput benchmark (hw/rtl/peripherals/nic, sw/lib/include/nic.h).
 *
 * Send frames to the port's own station address and receive them on the same
 * port, with PHY loopback off, so the line path is the one a transceiver
 * module or a loopback module closes: a QSFP loopback module on a transceiver
 * build, or a cable to a link partner that returns frames. TX and RX run
 * together at full duplex.
 *
 * The default build keeps up to 255 descriptors pending in each 256-entry
 * ring: every TX descriptor points at one prepared buffer, RX
 * descriptors follow the producer index, every frame's length and outcome are
 * checked, and one frame in SAMPLE_EVERY is compared byte for byte. The
 * result reports frames, elapsed time on the CPU timebase, and rates in
 * Gb/s: frame bytes (no preamble, FCS or gap) and wire bytes (+24 per frame).
 * The 10GBASE-R MAC rate is 10 Gb/s on the wire.
 *
 * Print <<PASS>> when lengths, statuses, sampled data and counters pass,
 * otherwise <<FAIL>>. Rings
 * and buffers use fixed DDR addresses above the program image.
 */
#include <stdint.h>

#include "csr.h"
#include "nic.h"
#include "trap.h"
#include "uart.h"

#ifndef FPGA_CPU_CLK_FREQ
#define FPGA_CPU_CLK_FREQ 200000000ull
#endif
#define TIMEBASE_HZ ((uint64_t) (FPGA_CPU_CLK_FREQ))
#define TIMEBASE_KHZ ((TIMEBASE_HZ >= 1000ull) ? (TIMEBASE_HZ / 1000ull) : 1ull)
#define WAIT_READY ((uint32_t) (TIMEBASE_HZ / 10u))
#define WAIT_CARRIER ((uint32_t) (2u * TIMEBASE_HZ))
#define STALL_TICKS (2ull * TIMEBASE_HZ) /* abort a run that moves nothing for 2 s */

#define DDR_SCRATCH 0x81800000u
#ifdef NIC_BENCH_QUICK
#define LOG2_ENTRIES 3u
#define BATCH 4u
#else
#define LOG2_ENTRIES 8u
#define BATCH 16u /* descriptors per doorbell */
#endif
#define ENTRIES (1u << LOG2_ENTRIES)
#define BUF_STRIDE 0x4000u /* 16 KiB per RX buffer: a jumbo frame with room */
#define RX_BUF_LEN 9216u
#define SAMPLE_EVERY 32u
static volatile struct nic_desc *const rx_ring = (volatile struct nic_desc *) (DDR_SCRATCH);
static volatile struct nic_desc *const tx_ring =
    (volatile struct nic_desc *) (DDR_SCRATCH + 0x1000u);
#define RX_BUF(i) (DDR_SCRATCH + 0x10000u + BUF_STRIDE * (i))
#define TX_BUF (DDR_SCRATCH + 0x600000u)

static const uint8_t station[6] = {0x02, 0x11, 0x22, 0x33, 0x44, 0x55};

static uint32_t g_rx_posted, g_rx_reaped, g_tx_posted, g_tx_done;

static uint8_t frame_byte(uint32_t i)
{
    if (i < 6)
        return station[i];
    if (i < 12)
        return station[i - 6];
    if (i == 12)
        return 0x88;
    if (i == 13)
        return 0xB5;
    return (uint8_t) (i * 7u + (i >> 8));
}

static int wait_status(uint32_t mask, uint32_t value, uint32_t budget)
{
    while (budget--) {
        if ((nic_read(NIC_STATUS) & mask) == value)
            return 1;
    }
    return 0;
}

static void prepare_rx(uint32_t n)
{
    for (uint32_t k = 0; k < n; k++) {
        uint32_t i = g_rx_posted % ENTRIES;
        rx_ring[i].addr = RX_BUF(i);
        rx_ring[i].len = RX_BUF_LEN;
        rx_ring[i].status = 0;
        g_rx_posted++;
    }
}

static void post_rx(uint32_t n)
{
    prepare_rx(n);
    __asm__ volatile("fence w, o" ::: "memory");
    nic_write(NIC_RX_TAIL, g_rx_posted % ENTRIES);
}

static int bringup(void)
{
    if (nic_read(NIC_ID) != NIC_ID_VALUE) {
        uart_printf("ID %x\n", nic_read(NIC_ID));
        return 0;
    }
    nic_write(NIC_PHY_CTRL, 0); /* no loopback inside the NIC or the transceiver */
    uart_printf("PHY_STATUS %x STATUS %x LINK %x\n",
                nic_read(NIC_PHY_STATUS),
                nic_read(NIC_STATUS),
                nic_read(NIC_LINK));
    const uint32_t ready = NIC_STATUS_RX_READY | NIC_STATUS_TX_READY;
    if (!wait_status(ready, ready, WAIT_READY)) {
        uart_printf("not READY: STATUS %x LINK %x\n", nic_read(NIC_STATUS), nic_read(NIC_LINK));
        return 0;
    }
#ifdef NIC_BENCH_QUICK
    nic_write(NIC_PHY_CTRL, NIC_PHY_CTRL_MAC_LOOPBACK);
    nic_write(NIC_CTRL, NIC_CTRL_RESET);
    if (!wait_status(NIC_STATUS_RESET_BUSY, 0, WAIT_READY) ||
        !wait_status(ready, ready, WAIT_READY))
        return 0;
#endif
    nic_write(NIC_MAC_LO,
              (uint32_t) station[0] | ((uint32_t) station[1] << 8) | ((uint32_t) station[2] << 16) |
                  ((uint32_t) station[3] << 24));
    nic_write(NIC_MAC_HI, (uint32_t) station[4] | ((uint32_t) station[5] << 8));
    nic_write(NIC_RX_BASE, (uint32_t) (uintptr_t) rx_ring);
    nic_write(NIC_RX_SIZE, LOG2_ENTRIES);
    nic_write(NIC_TX_BASE, (uint32_t) (uintptr_t) tx_ring);
    nic_write(NIC_TX_SIZE, LOG2_ENTRIES);
    g_rx_posted = g_rx_reaped = g_tx_posted = g_tx_done = 0;
    post_rx(ENTRIES - 1u);
    nic_write(NIC_RX_ITR, 0);
    nic_write(NIC_TX_ITR, 0);
    nic_write(NIC_IRQ_MASK, 0); /* polled */
    nic_write(NIC_IRQ_STATUS, NIC_IRQ_ALL);
    const uint32_t enables = NIC_CTRL_RX_EN | NIC_CTRL_TX_EN;
    for (uint32_t tries = 0; tries < 3u; tries++) {
        nic_write(NIC_CTRL, enables);
        if ((nic_read(NIC_CTRL) & enables) == enables)
            break;
        wait_status(ready, ready, WAIT_READY);
    }
    if ((nic_read(NIC_CTRL) & enables) != enables) {
        uart_printf(
            "enable refused: CTRL %x STATUS %x\n", nic_read(NIC_CTRL), nic_read(NIC_STATUS));
        return 0;
    }
    uint32_t budget = WAIT_CARRIER;
    while (budget-- && !(nic_read(NIC_LINK) & NIC_LINK_CARRIER))
        ;
    uint32_t link = nic_read(NIC_LINK);
    uart_printf("LINK %x PHY_STATUS %x\n", link, nic_read(NIC_PHY_STATUS));
    if (!(link & NIC_LINK_CARRIER)) {
        uart_printf("no carrier\n");
        return 0;
    }
    return 1;
}

struct counters {
    uint64_t tx_frames, rx_frames, tx_bytes, rx_bytes;
    uint64_t overflow, bad_fcs, bad_frame, pcs_bad, tx_drop, rx_trunc, rx_desc_err;
};

static void snapshot(struct counters *c)
{
    c->tx_frames = nic_read_counter(NIC_CNT_TX_FRAMES);
    c->rx_frames = nic_read_counter(NIC_CNT_RX_FRAMES);
    c->tx_bytes = nic_read_counter(NIC_CNT_TX_BYTES);
    c->rx_bytes = nic_read_counter(NIC_CNT_RX_BYTES);
    c->overflow = nic_read_counter(NIC_CNT_RX_MAC_OVERFLOW);
    c->bad_fcs = nic_read_counter(NIC_CNT_RX_MAC_BAD_FCS);
    c->bad_frame = nic_read_counter(NIC_CNT_RX_MAC_BAD_FRAME);
    c->pcs_bad =
        nic_read_counter(NIC_CNT_RX_PCS_BAD_BLOCK) + nic_read_counter(NIC_CNT_TX_PCS_BAD_BLOCK);
    c->tx_drop = nic_read_counter(NIC_CNT_TX_MAC_DROP);
    c->rx_trunc = nic_read_counter(NIC_CNT_RX_TRUNCATED);
    c->rx_desc_err = nic_read_counter(NIC_CNT_RX_DESC_ERR);
}

static void print_rate(const char *what, uint64_t bits, uint64_t ticks)
{
    uint64_t mbps = ticks ? bits * TIMEBASE_KHZ / (ticks * 1000ull) : 0; /* bits per us */
    uart_printf("%s %u.%03u Gb/s", what, (uint32_t) (mbps / 1000u), (uint32_t) (mbps % 1000u));
}

/* One run: send n frames of len bytes and receive them all. Return 1 when every
 * frame arrived with the expected length and status and the sampled frames
 * matched. */
static int run(uint32_t len, uint32_t n)
{
    uint32_t wire_len = len < 60u ? 60u : len;
    for (uint32_t i = 0; i < len; i++)
        ((volatile uint8_t *) (uintptr_t) TX_BUF)[i] = frame_byte(i);
    __asm__ volatile("fence w, o" ::: "memory");

    struct counters a, b;
    snapshot(&a);
    uint32_t tx_target = g_tx_posted + n; /* absolute counts, not modulo */
    uint32_t rx_target = g_rx_reaped + n;
    uint32_t bad_status = 0, bad_data = 0, tx_bad = 0, stalled = 0;
    uint32_t rx_count = 0, pending_tx = 0, pending_rx = 0;
    uint64_t t0 = rdmtime();
    uint64_t progress = t0;

    while (g_rx_reaped != rx_target) {
        int moved = 0;
        /* TX: refill the ring, one doorbell per batch. */
        while (g_tx_posted != tx_target && (g_tx_posted - g_tx_done) < ENTRIES - 1u) {
            uint32_t i = g_tx_posted % ENTRIES;
            tx_ring[i].addr = TX_BUF;
            tx_ring[i].len = len | NIC_TX_SOP | NIC_TX_EOP;
            tx_ring[i].status = 0;
            g_tx_posted++;
            pending_tx++;
            moved = 1;
            if (pending_tx == BATCH) {
                __asm__ volatile("fence w, o" ::: "memory");
                nic_write(NIC_TX_TAIL, g_tx_posted % ENTRIES);
                pending_tx = 0;
            }
        }
        if (pending_tx) {
            __asm__ volatile("fence w, o" ::: "memory");
            nic_write(NIC_TX_TAIL, g_tx_posted % ENTRIES);
            pending_tx = 0;
        }
        /* TX completions. */
        while (g_tx_done != g_tx_posted) {
            uint32_t st = tx_ring[g_tx_done % ENTRIES].status;
            if (!(st & NIC_DESC_DD))
                break;
            if (st != NIC_DESC_DD)
                tx_bad++;
            g_tx_done++;
            moved = 1;
        }
        /* RX completions: check, then fill the next producer slot. */
        while (g_rx_reaped != rx_target) {
            uint32_t i = g_rx_reaped % ENTRIES;
            uint32_t st = rx_ring[i].status;
            if (!(st & NIC_DESC_DD))
                break;
            __asm__ volatile("fence r, r" ::: "memory");
            if (st != (NIC_DESC_DD | wire_len)) {
                bad_status++;
            } else if ((rx_count % SAMPLE_EVERY) == 0u) {
                const volatile uint8_t *buf =
                    (const volatile uint8_t *) (uintptr_t) rx_ring[i].addr;
                for (uint32_t k = 0; k < wire_len; k++) {
                    uint8_t want = k < len ? frame_byte(k) : 0;
                    if (buf[k] != want) {
                        bad_data++;
                        break;
                    }
                }
            }
            rx_count++;
            g_rx_reaped++;
            prepare_rx(1);
            pending_rx++;
            moved = 1;
            if (pending_rx == BATCH) {
                __asm__ volatile("fence w, o" ::: "memory");
                nic_write(NIC_RX_TAIL, g_rx_posted % ENTRIES);
                pending_rx = 0;
            }
        }
        if (pending_rx) {
            __asm__ volatile("fence w, o" ::: "memory");
            nic_write(NIC_RX_TAIL, g_rx_posted % ENTRIES);
            pending_rx = 0;
        }
        uint64_t now = rdmtime();
        if (moved) {
            progress = now;
        } else if (now - progress > STALL_TICKS) {
            stalled = 1;
            break;
        }
    }
    uint64_t ticks = rdmtime() - t0;
    snapshot(&b);

    uint32_t got = rx_count;
    uint64_t frame_bits = (uint64_t) got * len * 8u;
    uint64_t wire_bits = (uint64_t) got * (wire_len + 24u) * 8u;
    uart_printf("len %u: %u of %u frames in %u us | ",
                len,
                got,
                n,
                (uint32_t) (ticks * 1000ull / TIMEBASE_KHZ));
    print_rate("frame", frame_bits, ticks);
    uart_printf(", ");
    print_rate("wire", wire_bits, ticks);
    uart_printf(" | %u kfps\n",
                (uint32_t) (ticks ? (uint64_t) got * TIMEBASE_HZ / ticks / 1000u : 0u));
    uint64_t d_overflow = b.overflow - a.overflow, d_fcs = b.bad_fcs - a.bad_fcs,
             d_frame = b.bad_frame - a.bad_frame, d_pcs = b.pcs_bad - a.pcs_bad,
             d_drop = b.tx_drop - a.tx_drop, d_trunc = b.rx_trunc - a.rx_trunc,
             d_desc = b.rx_desc_err - a.rx_desc_err;
    uart_printf("   hw tx %u rx %u frames; rx_overflow %u bad_fcs %u bad_frame %u pcs_bad %u "
                "tx_drop %u trunc %u desc_err %u; sw bad_status %u bad_data %u tx_bad %u%s\n",
                (uint32_t) (b.tx_frames - a.tx_frames),
                (uint32_t) (b.rx_frames - a.rx_frames),
                (uint32_t) d_overflow,
                (uint32_t) d_fcs,
                (uint32_t) d_frame,
                (uint32_t) d_pcs,
                (uint32_t) d_drop,
                (uint32_t) d_trunc,
                (uint32_t) d_desc,
                bad_status,
                bad_data,
                tx_bad,
                stalled ? " STALLED" : "");
    return !stalled && got == n && !bad_status && !bad_data && !tx_bad && !d_overflow && !d_fcs &&
           !d_frame && !d_pcs && !d_trunc && !d_desc && !d_drop;
}

int main(void)
{
    uart_printf("nic_bench\n");
    if (!bringup()) {
        uart_printf("bringup FAIL\n<<FAIL>>\n");
        return 1;
    }
    static const struct {
        uint32_t len, n;
    } plan[] = {
#ifdef NIC_BENCH_QUICK
        {64u, 41u},
        {128u, 17u},
        {9000u, 3u},
#else
        {64u, 200000u},
        {128u, 200000u},
        {256u, 100000u},
        {512u, 100000u},
        {1024u, 50000u},
        {1514u, 50000u},
        {4096u, 20000u},
        {9000u, 10000u},
#endif
    };
    int ok = 1;
    for (uint32_t k = 0; k < sizeof(plan) / sizeof(plan[0]); k++) {
        if (!run(plan[k].len, plan[k].n)) {
            ok = 0;
            uart_printf("len %u FAIL\n", plan[k].len);
            if (!(nic_read(NIC_LINK) & NIC_LINK_CARRIER))
                break;
        }
    }
    uart_printf(ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    return ok ? 0 : 1;
}
