// Copyright (c) 2026 John Goodacre.

/*
 * NIC loopback test (hw/rtl/peripherals/nic, sw/lib/include/nic.h).
 *
 * Send frames through loopback and compare every received byte. Use
 * MAC_LOOPBACK with a shared MAC clock and PMA_LOOPBACK with independent
 * transceiver clocks; select_loopback explains the clock constraint.
 *
 * Print <<PASS>> or <<FAIL>>. Rings and buffers use fixed DDR addresses above
 * the program image in either memory configuration.
 */
#include <stdint.h>

#include "aplic.h"
#include "csr.h"
#include "nic.h"
#include "trap.h"
#include "uart.h"

#ifndef MCAUSE_INTERRUPT_BIT
#define MCAUSE_INTERRUPT_BIT (1ul << 63)
#endif

/* Polling budgets count loop iterations: register waits read MMIO, and
 * descriptor and interrupt-flag waits poll memory. Short waits fit the
 * simulation budget. With CLK_SHARED = 0, reset, CDR and block lock
 * take hundreds of milliseconds; WAIT_LINK_TRANSCEIVER allows seconds at
 * 161 or 322 MHz. */
#define WAIT_READY 4000u
#define WAIT_CARRIER 12000u
#define WAIT_LINK_TRANSCEIVER 20000000u
#define WAIT_DONE 40000u
#define WAIT_IRQ 4000u

/* Bring-up's enable gets at most this many CTRL writes with a transceiver and
 * one where the MAC clock is shared (bringup). */
#define ENABLE_TRIES_TRANSCEIVER 3u

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
/* select_loopback sets the clock mode, PHY_CTRL loopback bit, wait budgets
 * and retry count. The loopback bit must survive RESET. */
static int g_transceiver;
static uint32_t g_loopback_ctrl;
static uint32_t g_wait_link_ready, g_wait_carrier, g_enable_tries;
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

static int wait_done(volatile struct nic_desc *d, uint32_t budget)
{
    while (budget--) {
        if (d->status & NIC_DESC_DONE)
            return 1;
    }
    return 0;
}

static void post_rx(uint32_t n)
{
    for (uint32_t k = 0; k < n; k++) {
        uint32_t i = g_rx_posted % ENTRIES;
        rx_ring[i].addr = RX_BUF(i) + (g_rx_posted % 7u) * 9u; /* varied alignments */
        rx_ring[i].len = RX_BUF_LEN;
        rx_ring[i].status = 0;
        g_rx_posted++;
    }
    __asm__ volatile("fence w, o" ::: "memory"); /* the descriptors before the doorbell */
    nic_write(NIC_RX_TAIL, g_rx_posted % ENTRIES);
}

/* Byte i of the frame sent as (da, seed): the destination MAC, then a
 * pattern. */
static uint8_t frame_byte(uint32_t i, const uint8_t *da, uint32_t seed)
{
    return i < 6 ? da[i] : (uint8_t) (seed * 31u + i * 7u + (i >> 8));
}

static void fill_frame(uint8_t *buf, uint32_t len, const uint8_t *da, uint32_t seed)
{
    for (uint32_t i = 0; i < len; i++)
        buf[i] = frame_byte(i, da, seed);
}

static uint32_t send_tx(uint32_t len, const uint8_t *da, uint32_t seed)
{
    uint32_t i = g_tx_posted % ENTRIES;
    uint32_t addr = TX_BUF(i) + (g_tx_posted % 5u) * 3u;
    fill_frame((uint8_t *) (uintptr_t) addr, len, da, seed);
    tx_ring[i].addr = addr;
    tx_ring[i].len = len | NIC_TX_FIRST | NIC_TX_LAST;
    tx_ring[i].status = 0;
    g_tx_posted++;
    __asm__ volatile("fence w, o" ::: "memory"); /* memory writes before the I/O doorbell */
    nic_write(NIC_TX_TAIL, g_tx_posted % ENTRIES);
    return i;
}

/* Reap the next RX descriptor and check that it holds the frame sent as
 * (len, da, seed). */
static int reap_rx(uint32_t len, const uint8_t *da, uint32_t seed, const char *what)
{
    uint32_t i = g_rx_reaped % ENTRIES;
    g_rx_reaped++;
    if (!wait_done(&rx_ring[i], WAIT_DONE)) {
        uart_printf("%s: RX descriptor %u never completed (status %x head %u)\n",
                    what,
                    i,
                    rx_ring[i].status,
                    nic_read(NIC_RX_HEAD));
        return 0;
    }
    uint32_t expected_len = len < 60u ? 60u : len;
    uint32_t status = rx_ring[i].status;
    if (status != (NIC_DESC_DONE | expected_len)) {
        uart_printf("%s: RX status %x, expected %x\n", what, status, NIC_DESC_DONE | expected_len);
        return 0;
    }
    __asm__ volatile("fence r, r" ::: "memory"); /* DONE before the data */
    const volatile uint8_t *buf = (const volatile uint8_t *) (uintptr_t) rx_ring[i].addr;
    for (uint32_t b = 0; b < expected_len; b++) {
        uint8_t w = b < len ? frame_byte(b, da, seed) : 0; /* the MAC pads with zeros */
        if (buf[b] != w) {
            uart_printf("%s: byte %u got %x want %x\n", what, b, buf[b], w);
            return 0;
        }
    }
    return 1;
}

/* The raw loopback inside the MAC wrapper feeds raw TX into the RX PCS with no
 * crossing logic, so it needs one clock shared by both MAC directions; with a
 * transceiver's independent clocks the transceiver loops back at its PMA. */
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

static int bringup(int loopback)
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
    if (loopback) {
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
    nic_write(NIC_RX_COALESCE, 0);
    nic_write(NIC_TX_COALESCE, 0);
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
    if (loopback) {
        uint32_t budget = g_wait_carrier;
        while (budget-- && !(nic_read(NIC_LINK) & NIC_LINK_CARRIER))
            ;
        if (!(nic_read(NIC_LINK) & NIC_LINK_CARRIER)) {
            uart_printf("no carrier: LINK %x\n", nic_read(NIC_LINK));
            return 0;
        }
        if (g_transceiver && !reenable_after_ready_loss())
            return 0;
    }
    return 1;
}


/* ---- scatter-gather and checksum offload ------------------------------------------------
 * A frame is sent as several descriptors (FIRST on the initial, LAST on the final, one per
 * segment). The MAC joins the segments into one frame, so the received bytes must be the
 * segments' concatenation. The FIRST descriptor can also carry a checksum request in the
 * upper bits of its length word: start/2 in [24:18], offset/2 in [31:25]. The MAC then
 * writes the ones-complement sum of the frame from byte `start` at byte start + offset.
 * One print per segment keeps device reads between bursts of stores to DDR. ---- */
#define SG_MAX_FRAME 1100u

static void apply_csum(uint8_t *f, uint32_t len, uint32_t start, uint32_t off)
{
    uint32_t sum = 0;
    for (uint32_t i = start; i < len; i += 2u) {
        uint32_t lo = (i + 1u < len) ? f[i + 1u] : 0u;
        sum += ((uint32_t) f[i] << 8) | lo;
    }
    while (sum >> 16)
        sum = (sum & 0xFFFFu) + (sum >> 16);
    uint16_t v = (sum == 0xFFFFu) ? 0xFFFFu : (uint16_t) ~sum;
    f[start + off] = (uint8_t) (v >> 8);
    f[start + off + 1u] = (uint8_t) (v & 0xFFu);
}

/* Send one frame of nseg segments built from frame_byte(). csum_off 0 means no request. */
static int send_sg(
    const uint32_t *seg_len, uint32_t nseg, uint32_t seed, uint32_t csum_start, uint32_t csum_off)
{
    uint32_t total = 0;
    for (uint32_t k = 0; k < nseg; k++)
        total += seg_len[k];
    uint32_t idx[8];
    if (nseg > 8u || nseg == 0u)
        return 0;
    uint32_t off = 0;
    for (uint32_t k = 0; k < nseg; k++) {
        uint32_t i = g_tx_posted % ENTRIES;
        uint32_t addr =
            TX_BUF(i) + 0x2000u + k * 0x200u + (k % 3u); /* separate buffers, odd offsets */
        for (uint32_t b = 0; b < seg_len[k]; b++)
            ((uint8_t *) (uintptr_t) addr)[b] = frame_byte(off + b, station, seed);
        off += seg_len[k];
        uart_printf("sg: segment %u filled\n", k);
        uint32_t flags = (k == 0u ? NIC_TX_FIRST : 0u) | (k == nseg - 1u ? NIC_TX_LAST : 0u);
        if (k == 0u && csum_off != 0u)
            flags |= ((csum_start / 2u) << 18) | ((csum_off / 2u) << 25);
        else if (k != 0u)
            flags |= 0xFFFC0000u & (0x5A5A5A5Au << 18); /* junk above bit 17 must be ignored */
        idx[k] = i;
        tx_ring[i].addr = addr;
        tx_ring[i].len = seg_len[k] | flags;
        tx_ring[i].status = 0;
        g_tx_posted++;
    }
    __asm__ volatile("fence w, o" ::: "memory");
    nic_write(NIC_TX_TAIL, g_tx_posted % ENTRIES);
    /* The frame completes when its last segment does; each segment completes too. */
    if (!wait_done(&tx_ring[idx[nseg - 1u]], WAIT_DONE)) {
        uart_printf("sg: last segment never completed, status %x TX_HEAD %u\n",
                    tx_ring[idx[nseg - 1u]].status,
                    nic_read(NIC_TX_HEAD));
        return 0;
    }
    for (uint32_t k = 0; k < nseg; k++) {
        if (!wait_done(&tx_ring[idx[k]], WAIT_DONE) || tx_ring[idx[k]].status != NIC_DESC_DONE) {
            uart_printf("sg: segment %u status %x\n", k, tx_ring[idx[k]].status);
            return 0;
        }
    }
    return (int) total;
}

/* Reap the next RX descriptor and check it against an expected byte array (a frame
 * shorter than 60 bytes arrives zero-padded). */
static int reap_rx_bytes(const uint8_t *expect, uint32_t len, const char *what)
{
    uint32_t i = g_rx_reaped % ENTRIES;
    g_rx_reaped++;
    if (!wait_done(&rx_ring[i], WAIT_DONE)) {
        uart_printf("%s: RX descriptor %u never completed\n", what, i);
        return 0;
    }
    uint32_t want = len < 60u ? 60u : len;
    uint32_t status = rx_ring[i].status;
    if (status != (NIC_DESC_DONE | want)) {
        uart_printf("%s: RX status %x, expected %x\n", what, status, NIC_DESC_DONE | want);
        return 0;
    }
    __asm__ volatile("fence r, r" ::: "memory");
    const volatile uint8_t *buf = (const volatile uint8_t *) (uintptr_t) rx_ring[i].addr;
    for (uint32_t b = 0; b < want; b++) {
        uint8_t w = b < len ? expect[b] : 0;
        if (buf[b] != w) {
            uart_printf("%s: byte %u got %x want %x\n", what, b, buf[b], w);
            return 0;
        }
    }
    return 1;
}

static void test_sg(void)
{
    static const uint32_t frames[][5] = {
        {13u, 7u, 100u, 0u, 0u},
        {1u, 9u, 0u, 0u, 0u},
        {8u, 8u, 8u, 0u, 0u},
        {3u, 2u, 1u, 50u, 6u},
        {200u, 1u, 1u, 1u, 300u},
    };
    static const uint32_t nseg[] = {3u, 2u, 3u, 5u, 5u};
    int ok = 1;
    for (uint32_t f = 0; f < sizeof(nseg) / sizeof(nseg[0]); f++) {
        uint32_t total = 0;
        for (uint32_t k = 0; k < nseg[f]; k++)
            total += frames[f][k];
        int sent = send_sg(frames[f], nseg[f], 40u + f, 0u, 0u);
        int got = sent && reap_rx(total, station, 40u + f, "sg");
        uart_printf(
            "sg frame %u: %u segments, %u bytes: %s\n", f, nseg[f], total, got ? "OK" : "FAIL");
        if (!got)
            ok = 0;
    }
    check("sg", ok);
}

/* Checksum frames: the expected bytes are the frame pattern with the sum written at
 * start + offset (TCP-like offset 16, UDP-like offset 6, segment ends mid-word, an odd
 * length, and a request that must leave the frame alone). */
static void test_csum(void)
{
    static const struct {
        uint32_t seg[5];
        uint32_t nseg, start, off;
    } cases[] = {
        {{70u, 30u, 0u, 0u, 0u}, 2u, 34u, 16u},   /* TCP: 34 + 16 = 50, inside segment 0 */
        {{41u, 39u, 20u, 0u, 0u}, 3u, 34u, 6u},   /* UDP: field at 40, segment ends mid-word */
        {{13u, 1u, 62u, 0u, 0u}, 3u, 14u, 10u},   /* odd length 76, field at 24 */
        {{300u, 7u, 3u, 500u, 1u}, 5u, 34u, 16u}, /* 811 bytes, odd, five segments */
        {{80u, 0u, 0u, 0u, 0u}, 1u, 34u, 16u},    /* one segment */
        {{60u, 0u, 0u, 0u, 0u}, 1u, 20u, 0u},     /* offset 0: no request, unchanged */
    };
    int ok = 1;
    static uint8_t expect[SG_MAX_FRAME];
    for (uint32_t c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
        uint32_t total = 0;
        for (uint32_t k = 0; k < cases[c].nseg; k++)
            total += cases[c].seg[k];
        uint32_t seed = 70u + c;
        for (uint32_t b = 0; b < total; b++)
            expect[b] = frame_byte(b, station, seed);
        if (cases[c].off != 0u)
            apply_csum(expect, total, cases[c].start, cases[c].off);
        int sent = send_sg(cases[c].seg, cases[c].nseg, seed, cases[c].start, cases[c].off);
        int got = sent && reap_rx_bytes(expect, total, "csum");
        uart_printf("csum frame %u: %u bytes, start %u offset %u: %s\n",
                    c,
                    total,
                    cases[c].start,
                    cases[c].off,
                    got ? "OK" : "FAIL");
        if (!got)
            ok = 0;
    }
    check("csum", ok);
}

/* ---- TCP segmentation offload: a parameter descriptor, then the frame as an SG chain ----------
 */

#define SEG_MAX_PKT 3400u
/* The packet and the expected segment live in cached DDR, where the NIC can read the packet. */
#define seg_pkt ((uint8_t *) (uintptr_t) (DDR_SCRATCH + 0x100000u))
#define seg_want ((uint8_t *) (uintptr_t) (DDR_SCRATCH + 0x110000u))

static uint32_t g_lcg = 12345u;
static uint8_t lcg_byte(void)
{
    g_lcg = g_lcg * 1103515245u + 12345u;
    return (uint8_t) (g_lcg >> 16);
}

/* Ones-complement sum of big-endian 16-bit words, an odd last byte padded with zero. */
static uint32_t sum16(const uint8_t *p, uint32_t n, uint32_t acc)
{
    for (uint32_t i = 0; i + 1u < n; i += 2u)
        acc += ((uint32_t) p[i] << 8) | p[i + 1u];
    if (n & 1u)
        acc += (uint32_t) p[n - 1u] << 8;
    return acc;
}

static uint32_t fold16(uint32_t s)
{
    while (s >> 16)
        s = (s & 0xFFFFu) + (s >> 16);
    return s;
}

struct seg_case {
    uint32_t ip6, vlan, ip_opt, tcp_opt, payload, mss, flags, id0, seq0;
};

struct seg_geom {
    uint32_t l3, ip_len, l4, tcp_hl, hdr_len;
};

static struct seg_geom seg_geometry(const struct seg_case *c)
{
    struct seg_geom g;
    g.l3 = c->vlan ? 18u : 14u;
    g.ip_len = c->ip6 ? 40u : 20u + 4u * c->ip_opt;
    g.l4 = g.l3 + g.ip_len;
    g.tcp_hl = 20u + 4u * c->tcp_opt;
    g.hdr_len = g.l4 + g.tcp_hl;
    return g;
}

/* The pseudo-header sum of a segment of tcp_len bytes (the sum without it for tcp_len 0). */
static uint32_t pseudo_sum(const struct seg_case *c,
                           const struct seg_geom *g,
                           const uint8_t *frame,
                           uint32_t tcp_len)
{
    uint32_t s;
    if (c->ip6) {
        s = sum16(frame + g->l3 + 8u, 32u, 0);
        s += tcp_len >> 16;
        s += tcp_len & 0xFFFFu;
    } else {
        s = sum16(frame + g->l3 + 12u, 8u, 0);
        s += tcp_len;
    }
    return s + 6u;
}

static void seg_build(const struct seg_case *c, struct seg_geom *g)
{
    *g = seg_geometry(c);
    uint8_t *p = seg_pkt;
    uint32_t o = 0;
    for (uint32_t i = 0; i < 6u; i++)
        p[o++] = station[i];
    for (uint32_t i = 0; i < 6u; i++)
        p[o++] = other[i];
    if (c->vlan) {
        p[o++] = 0x81u;
        p[o++] = 0x00u;
        p[o++] = 0x20u;
        p[o++] = 0x05u;
    }
    p[o++] = c->ip6 ? 0x86u : 0x08u;
    p[o++] = c->ip6 ? 0xDDu : 0x00u;
    if (c->ip6) {
        p[o++] = 0x60u;
        p[o++] = 0x01u;
        p[o++] = 0x23u;
        p[o++] = 0x45u;
        p[o++] = 0xBEu; /* payload length: the hardware sets it */
        p[o++] = 0xEFu;
        p[o++] = 6u;
        p[o++] = 64u;
        for (uint32_t i = 0; i < 32u; i++)
            p[o++] = lcg_byte();
    } else {
        p[o++] = (uint8_t) (0x40u | (5u + c->ip_opt));
        p[o++] = lcg_byte();
        p[o++] = 0xBEu; /* total length: the hardware sets it */
        p[o++] = 0xEFu;
        p[o++] = (uint8_t) (c->id0 >> 8);
        p[o++] = (uint8_t) c->id0;
        p[o++] = 0x40u;
        p[o++] = 0x00u;
        p[o++] = 64u;
        p[o++] = 6u;
        p[o++] = 0x12u; /* header checksum: the hardware sets it */
        p[o++] = 0x34u;
        for (uint32_t i = 0; i < 8u + 4u * c->ip_opt; i++)
            p[o++] = lcg_byte();
    }
    /* TCP */
    p[o++] = 0x12u;
    p[o++] = 0x34u;
    p[o++] = 0x56u;
    p[o++] = 0x78u;
    for (uint32_t i = 0; i < 4u; i++)
        p[o++] = (uint8_t) (c->seq0 >> (24u - 8u * i));
    for (uint32_t i = 0; i < 4u; i++)
        p[o++] = lcg_byte();
    p[o++] = (uint8_t) ((g->tcp_hl / 4u) << 4);
    p[o++] = (uint8_t) c->flags;
    p[o++] = 0x20u;
    p[o++] = 0x00u;
    uint32_t check_at = o;
    o += 2u; /* the checksum field: the pseudo-header sum without the length */
    p[o++] = 0u;
    p[o++] = 0u;
    for (uint32_t i = 0; i < 4u * c->tcp_opt; i++)
        p[o++] = lcg_byte();
    for (uint32_t i = 0; i < c->payload; i++)
        p[o++] = lcg_byte();
    uint32_t seed = fold16(pseudo_sum(c, g, p, 0));
    p[check_at] = (uint8_t) (seed >> 8);
    p[check_at + 1u] = (uint8_t) seed;
}

/* Post the parameter descriptor, then the packet as three segments: the headers plus three
 * payload bytes, half of the rest, and the remainder, so the cuts fall mid-word. */
static int seg_send(const struct seg_case *c, const struct seg_geom *g)
{
    uint32_t total = g->hdr_len + c->payload;
    uint32_t cuts[3];
    cuts[0] = g->hdr_len + 3u;
    cuts[1] = (total - cuts[0]) / 2u;
    cuts[2] = total - cuts[0] - cuts[1];
    uint32_t first = g_tx_posted % ENTRIES;
    uint32_t i = first;
    tx_ring[i].addr = c->mss | (c->payload << 16);
    tx_ring[i].len = NIC_TX_PARAM | ((g->l4 / 2u) << 19) | ((g->tcp_hl / 4u) << 26) |
                     (c->ip6 << 30) | (c->vlan << 31);
    tx_ring[i].status = 0;
    g_tx_posted++;
    uint32_t pos = 0;
    uint32_t last = i;
    for (uint32_t k = 0; k < 3u; k++) {
        i = g_tx_posted % ENTRIES;
        tx_ring[i].addr = (uint32_t) (uintptr_t) (seg_pkt + pos);
        tx_ring[i].len = cuts[k] | (k == 0 ? NIC_TX_FIRST : 0u) | (k == 2u ? NIC_TX_LAST : 0u);
        tx_ring[i].status = 0;
        pos += cuts[k];
        g_tx_posted++;
        last = i;
    }
    __asm__ volatile("fence w, o" ::: "memory");
    nic_write(NIC_TX_TAIL, g_tx_posted % ENTRIES);
    return wait_done(&tx_ring[last], WAIT_DONE * 8u) && (tx_ring[first].status & NIC_DESC_DONE) &&
           !(tx_ring[first].status & NIC_DESC_ERR);
}

/* One received segment k against the packet: lengths, every header byte that should not change,
 * the fields that should, the IPv4 header checksum, the TCP checksum over the pseudo-header, and
 * the payload. */
static int seg_check_segment(const struct seg_case *c,
                             const struct seg_geom *g,
                             uint32_t k,
                             uint32_t sent,
                             uint32_t plen,
                             int last)
{
    uint32_t i = g_rx_reaped % ENTRIES;
    g_rx_reaped++;
    if (!wait_done(&rx_ring[i], WAIT_DONE * 4u)) {
        uart_printf("seg %u: RX descriptor never completed\n", k);
        return 0;
    }
    uint32_t len = g->hdr_len + plen;
    uint32_t status = rx_ring[i].status;
    if (status != (NIC_DESC_DONE | len)) {
        uart_printf("seg %u: status %x, expected %x\n", k, status, NIC_DESC_DONE | len);
        return 0;
    }
    __asm__ volatile("fence r, r" ::: "memory");
    const uint8_t *f = (const uint8_t *) (uintptr_t) rx_ring[i].addr;
    /* The expected frame: the packet's header and this segment's payload, with the fields set. */
    for (uint32_t b = 0; b < g->hdr_len; b++)
        seg_want[b] = seg_pkt[b];
    for (uint32_t b = 0; b < plen; b++)
        seg_want[g->hdr_len + b] = seg_pkt[g->hdr_len + sent + b];
    uint32_t seq = c->seq0 + sent;
    for (uint32_t b = 0; b < 4u; b++)
        seg_want[g->l4 + 4u + b] = (uint8_t) (seq >> (24u - 8u * b));
    uint32_t fl = c->flags;
    if (!last)
        fl &= ~0x09u;
    if (k != 0)
        fl &= ~0x80u;
    seg_want[g->l4 + 13u] = (uint8_t) fl;
    if (c->ip6) {
        uint32_t pl = g->hdr_len - g->l3 - 40u + plen;
        seg_want[g->l3 + 4u] = (uint8_t) (pl >> 8);
        seg_want[g->l3 + 5u] = (uint8_t) pl;
    } else {
        uint32_t tl = g->hdr_len - g->l3 + plen;
        uint32_t id = (c->id0 + k) & 0xFFFFu;
        seg_want[g->l3 + 2u] = (uint8_t) (tl >> 8);
        seg_want[g->l3 + 3u] = (uint8_t) tl;
        seg_want[g->l3 + 4u] = (uint8_t) (id >> 8);
        seg_want[g->l3 + 5u] = (uint8_t) id;
    }
    for (uint32_t b = 0; b < len; b++) {
        int skip = (b >= g->l4 + 16u && b < g->l4 + 18u) ||
                   (!c->ip6 && b >= g->l3 + 10u && b < g->l3 + 12u);
        if (!skip && f[b] != seg_want[b]) {
            uart_printf("seg %u: byte %u got %x want %x\n", k, b, f[b], seg_want[b]);
            return 0;
        }
    }
    if (!c->ip6 && fold16(sum16(f + g->l3, g->ip_len, 0)) != 0xFFFFu) {
        uart_printf("seg %u: IPv4 header checksum bad\n", k);
        return 0;
    }
    uint32_t tcp_len = g->tcp_hl + plen;
    uint32_t s = pseudo_sum(c, g, f, tcp_len) + sum16(f + g->l4, tcp_len, 0);
    if (fold16(s) != 0xFFFFu) {
        uart_printf("seg %u: TCP checksum bad (sum %x)\n", k, fold16(s));
        return 0;
    }
    return 1;
}

static int seg_case_run(const struct seg_case *c)
{
    struct seg_geom g;
    post_rx(g_rx_reaped + (ENTRIES - 1u) - g_rx_posted);
    seg_build(c, &g);
    if (!seg_send(c, &g)) {
        uart_printf("seg: send failed\n");
        return 0;
    }
    int ok = 1;
    uint32_t sent = 0, k = 0;
    while (sent < c->payload) {
        uint32_t plen = c->payload - sent < c->mss ? c->payload - sent : c->mss;
        int last = (sent + plen == c->payload);
        if (!seg_check_segment(c, &g, k, sent, plen, last)) {
            ok = 0;
            break;
        }
        sent += plen;
        k++;
        if ((k & 3u) == 0u)
            post_rx(g_rx_reaped + (ENTRIES - 1u) - g_rx_posted);
    }
    uart_printf("seg %s%s ip_opt %u tcp_opt %u: %u bytes at mss %u in %u segments: %s\n",
                c->ip6 ? "ipv6" : "ipv4",
                c->vlan ? " vlan" : "",
                c->ip_opt,
                c->tcp_opt,
                c->payload,
                c->mss,
                k,
                ok ? "OK" : "FAIL");
    return ok;
}

static void test_segment(void)
{
    static const struct seg_case cases[] = {
        {0u, 0u, 0u, 0u, 3000u, 1000u, 0x19u | 0x80u, 0xFFFEu, 0xFFFFFF00u}, /* ACK PSH FIN CWR; id
                                                                                and seq wrap */
        {0u, 1u, 1u, 2u, 2500u, 777u, 0x10u | 0x08u, 0x1000u, 0x10000000u},
        {1u, 0u, 0u, 1u, 1999u, 600u, 0x10u | 0x01u, 0u, 0x7FFFFFF0u},
        {1u, 1u, 0u, 0u, 1460u, 1460u, 0x10u, 0u, 5u}, /* one segment, exactly the MSS */
    };
    int ok = 1;
    for (uint32_t c = 0; c < sizeof(cases) / sizeof(cases[0]); c++)
        ok &= seg_case_run(&cases[c]);
    check("segment", ok);
}

/* The ones-complement sum of the padded frame from byte 14 (16-bit big-endian words), as the
 * kernel's folded sum on a little-endian CPU: the two bytes swapped. */
static uint32_t rx_csum_expected(uint32_t len, uint32_t want, uint32_t seed)
{
    uint32_t sum = 0;
    for (uint32_t b = 14u; b < want; b += 2u) {
        uint32_t hi = b < len ? frame_byte(b, station, seed) : 0u;
        uint32_t lo = (b + 1u) < len ? frame_byte(b + 1u, station, seed) : 0u;
        sum += (hi << 8) | lo;
    }
    while (sum >> 16)
        sum = (sum & 0xFFFFu) + (sum >> 16);
    return ((sum >> 8) | (sum << 8)) & 0xFFFFu;
}

/* ABI_CTRL.RX_CSUM changes only while both directions are disabled and idle. */
static int enable_rx_csum(void)
{
    const uint32_t enables = NIC_CTRL_RX_EN | NIC_CTRL_TX_EN;
    uint32_t promisc = nic_read(NIC_CTRL) & NIC_CTRL_PROMISC;
    if (!(nic_read(NIC_ABI_CTRL) & NIC_ABI_RX_CSUM_SUPPORTED))
        return 0;
    nic_write(NIC_CTRL, promisc);
    if (!wait_status(NIC_STATUS_RX_IDLE | NIC_STATUS_TX_IDLE,
                     NIC_STATUS_RX_IDLE | NIC_STATUS_TX_IDLE,
                     WAIT_DONE))
        return 0;
    nic_write(NIC_ABI_CTRL, NIC_ABI_RX_CSUM);
    if (!(nic_read(NIC_ABI_CTRL) & NIC_ABI_RX_CSUM))
        return 0;
    post_rx(g_rx_reaped + (ENTRIES - 1u) - g_rx_posted);
    nic_write(NIC_CTRL, enables | promisc);
    for (uint32_t tries = 1u; (nic_read(NIC_CTRL) & enables) != enables; tries++) {
        if (tries >= g_enable_tries || !wait_status(NIC_STATUS_RX_READY | NIC_STATUS_TX_READY,
                                                    NIC_STATUS_RX_READY | NIC_STATUS_TX_READY,
                                                    g_wait_link_ready))
            return 0;
        nic_write(NIC_CTRL, enables | promisc);
    }
    return 1;
}

static void test_rx_csum(void)
{
    static const uint32_t lens[] = {60u, 61u, 14u, 15u, 100u, 511u, 1514u};
    int ok = enable_rx_csum();
    if (!ok)
        uart_printf("rx csum: enable failed\n");
    for (uint32_t c = 0; ok && c < sizeof(lens) / sizeof(lens[0]); c++) {
        uint32_t len = lens[c], seed = 90u + c;
        uint32_t want = len < 60u ? 60u : len;
        uint32_t i = g_rx_reaped % ENTRIES;
        send_tx(len, station, seed);
        g_rx_reaped++;
        int got = wait_done(&rx_ring[i], WAIT_DONE);
        uint32_t status = rx_ring[i].status;
        __asm__ volatile("fence r, r" ::: "memory");
        uint32_t csum = rx_ring[i].reserved & 0xFFFFu;
        uint32_t want_csum = rx_csum_expected(len, want, seed);
        got = got && status == (NIC_DESC_DONE | NIC_DESC_SUM_VALID | want) && csum == want_csum;
        uart_printf("rx csum frame %u: %u bytes status %x csum %x want %x: %s\n",
                    c,
                    len,
                    status,
                    csum,
                    want_csum,
                    got ? "OK" : "FAIL");
        if (!got)
            ok = 0;
        post_rx(1u);
    }
    check("rx csum", ok);
}

/* Loopback rate: frames of 64 to 1514 bytes, up to RATE_INFLIGHT in flight, one prepared TX buffer,
 * so the loop's own cost is a few memory accesses per frame. Prints bytes per cycle of the system
 * clock; the NIC runs at the SoC clock (100 MHz on the VCU118 build). */
#define RATE_FRAMES 64u
#define RATE_INFLIGHT 8u
static int rate_run(uint32_t RATE_LEN)
{
    uint32_t tx_addr = TX_BUF(0);
    fill_frame((uint8_t *) (uintptr_t) tx_addr, RATE_LEN, station, 5u);
    uint32_t sent = 0, rcvd = 0, bad = 0, spins = 0;
    uint32_t t0 = rdcycle();
    while (rcvd < RATE_FRAMES && spins < 4000000u) {
        uint32_t batch = 0;
        while (sent < RATE_FRAMES && (sent - rcvd) < RATE_INFLIGHT) {
            uint32_t i = g_tx_posted % ENTRIES;
            tx_ring[i].addr = tx_addr;
            tx_ring[i].len = RATE_LEN | NIC_TX_FIRST | NIC_TX_LAST;
            tx_ring[i].status = 0;
            g_tx_posted++;
            sent++;
            batch++;
        }
        if (batch) {
            __asm__ volatile("fence w, o" ::: "memory");
            nic_write(NIC_TX_TAIL, g_tx_posted % ENTRIES);
        }
        uint32_t r = g_rx_reaped % ENTRIES;
        uint32_t status = rx_ring[r].status;
        if (status & NIC_DESC_DONE) {
            if ((status & NIC_DESC_LEN_MASK) != RATE_LEN ||
                (status & (NIC_DESC_ERR | NIC_DESC_TRUNC)))
                bad++;
            g_rx_reaped++;
            rcvd++;
            post_rx(1u);
        } else {
            spins++;
        }
    }
    uint32_t cycles = rdcycle() - t0;
    uint32_t bytes = rcvd * RATE_LEN;
    uint32_t milli_gbps = cycles ? (uint32_t) ((uint64_t) bytes * 800u / cycles) : 0u;
    uart_printf("rate: %u of %u frames of %u bytes in %u cycles = %u.%02u bytes/cycle, %u.%03u "
                "Gb/s at 100 MHz\n",
                rcvd,
                RATE_FRAMES,
                RATE_LEN,
                cycles,
                bytes / cycles,
                (uint32_t) ((uint64_t) bytes * 100u / cycles % 100u),
                milli_gbps / 1000u,
                milli_gbps % 1000u);
    return rcvd == RATE_FRAMES && bad == 0;
}

static void test_rate(void)
{
    static const uint32_t lens[] = {64u, 256u, 760u, 1514u};
    int ok = 1;
    for (uint32_t k = 0; k < sizeof(lens) / sizeof(lens[0]); k++)
        ok &= rate_run(lens[k]);
    check("rate", ok);
}

/* TX alone: RX disabled, so the frames the raw loopback returns are dropped in the MAC and the
 * DMA port serves only the TX engine. One prepared buffer, RATE_INFLIGHT frames in flight. */
/* cold: every frame comes from its own buffer that nothing has written, so each line the NIC
 * reads misses the L2 and is served by DDR (the simulation's DDR_MODEL_LATENCY). */
#define COLD_BASE (DDR_SCRATCH + 0x800000u)
static int tx_rate_run(uint32_t len, int cold)
{
    uint32_t tx_addr = TX_BUF(0);
    if (!cold)
        fill_frame((uint8_t *) (uintptr_t) tx_addr, len, station, 6u);
    uint32_t sent = 0, done = 0, bad = 0, spins = 0;
    uint32_t t0 = rdcycle();
    while (done < RATE_FRAMES && spins < 4000000u) {
        uint32_t batch = 0;
        while (sent < RATE_FRAMES && (sent - done) < RATE_INFLIGHT) {
            uint32_t i = g_tx_posted % ENTRIES;
            tx_ring[i].addr = cold ? COLD_BASE + sent * 0x2000u : tx_addr;
            tx_ring[i].len = len | NIC_TX_FIRST | NIC_TX_LAST;
            tx_ring[i].status = 0;
            g_tx_posted++;
            sent++;
            batch++;
        }
        if (batch) {
            __asm__ volatile("fence w, o" ::: "memory");
            nic_write(NIC_TX_TAIL, g_tx_posted % ENTRIES);
        }
        uint32_t status = tx_ring[(g_tx_posted - (sent - done)) % ENTRIES].status;
        if (status & NIC_DESC_DONE) {
            if (status & (NIC_DESC_ERR | NIC_DESC_ABORT))
                bad++;
            done++;
        } else {
            spins++;
        }
    }
    uint32_t cycles = rdcycle() - t0;
    uint32_t bytes = done * len;
    uart_printf("tx-only%s rate: %u of %u frames of %u bytes in %u cycles = %u.%02u bytes/cycle, "
                "%u.%03u Gb/s at 100 MHz\n",
                cold ? " cold" : "",
                done,
                RATE_FRAMES,
                len,
                cycles,
                bytes / cycles,
                (uint32_t) ((uint64_t) bytes * 100u / cycles % 100u),
                (uint32_t) ((uint64_t) bytes * 800u / cycles / 1000u),
                (uint32_t) ((uint64_t) bytes * 800u / cycles % 1000u));
    return done == RATE_FRAMES && bad == 0;
}

static void test_tx_rate(void)
{
    uint32_t promisc = nic_read(NIC_CTRL) & NIC_CTRL_PROMISC;
    nic_write(NIC_CTRL, NIC_CTRL_TX_EN | promisc);
    int ok = tx_rate_run(1514u, 0);
    ok &= tx_rate_run(512u, 0);
    ok &= tx_rate_run(1514u, 1);
    ok &= tx_rate_run(512u, 1);
    check("tx rate", ok);
}

int main(void)
{
    uart_printf("nic_sg_loopback\n");
    select_loopback();
    if (!bringup(1)) {
        uart_printf("bringup FAIL\n<<FAIL>>\n");
        return 1;
    }
    uart_printf("bringup OK\n");
#ifdef NIC_RATE_ONLY
    test_tx_rate();
    uart_printf(g_failures == 0 ? "<<PASS>>\n" : "<<FAIL>>\n");
    return 0;
#endif
    test_sg();
    test_csum();
    test_segment();
    test_rx_csum();
    test_rate();
    test_tx_rate();
    if (g_failures == 0) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("%u failures\n<<FAIL>>\n", g_failures);
    }
    return 0;
}
