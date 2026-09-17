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
 * frost_nettest: the frost,net10g driver through its loopback feature.
 *
 * The hardware regression's Linux stage types this at the root shell. It
 * uses the interface whose ETHTOOL_GDRVINFO driver is frost_net10g. The
 * driver implements the loopback feature as the NIC's MAC loopback when both
 * MAC directions share one clock and as the transceiver's PMA loopback
 * otherwise; nothing here depends on which. It prints one progress line per
 * step:
 *
 *   1. Find the interface and its "loopback" feature bit; take it down.
 *   2. MTU 9000; loopback on (ETHTOOL_SFEATURES on the "loopback" feature
 *      string, checked with ETHTOOL_GFEATURES); up; carrier within 5 s.
 *   3. One frame at a time: lengths 14..160, 1514, 4096 and 9014. A frame
 *      shorter than 60 bytes arrives padded to 60 with its own bytes first.
 *   4. A burst of 300 frames before receiving, which wraps both rings: order,
 *      contents, no socket drops.
 *   5. A burst of 64 frames, then down at once (the drain; the tx_dropped and
 *      rx_packets deltas are printed, not judged). Loopback off, up for 2 s,
 *      down: nothing in that interval is judged, since the transceiver may
 *      face a link partner that raises the carrier and sends frames
 *      (broadcasts, say); when the carrier first read 1 is printed. Loopback
 *      on, up: a burst of 64 verified.
 *   6. The driver's tx_packets and rx_packets cover the frames of steps 3, 4
 *      and 5's last burst, no frame is counted while none is being sent, and
 *      rx_errors and tx_errors are unchanged. The loopback-off interval is
 *      left out of both the idle and the error checks.
 *   7. Down with loopback off (also after a failure), then the verdict:
 *
 *   FROST_NET_LOOPBACK_PASS
 *   FROST_NET_LOOPBACK_FAIL <reason>
 *
 * Frames go from the interface's own address to itself with ethertype 0x88B5
 * over an AF_PACKET socket that is opened again after every up (a down
 * leaves ENETDOWN pending on a bound socket). Each frame carries a tag: a
 * sequence number that is never reused within the run, a run identifier and
 * its length, so a lost, duplicated, reordered, stale (sent before a down or,
 * unless the identifiers collide, by an earlier run) or corrupted frame fails
 * the step. A frame shorter than the 24 bytes of header and tag holds only
 * part of the tag (a 14-byte frame none of it); for those the bytes sent and
 * the padded length are checked. After each verified burst, no further frame
 * may arrive for half a second.
 *
 * Every wait the program makes is bounded (one step's frames get 10 s); a
 * system call that never returns is left to the caller's timeout. The kernel
 * has no IP stack: all control goes through ioctls and sysfs.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/ethtool.h>
#include <linux/if_packet.h>
#include <linux/sockios.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define DRIVER_NAME "frost_net10g"
#define ETHERTYPE_TEST 0x88B5 /* IEEE 802 local experimental ethertype 1 */
#define TEST_MTU 9000
#define HDR_BYTES 14
#define TAG_BYTES 10 /* sequence (4), run (4), length (2), little-endian */
#define MIN_FRAME 60 /* the MAC pads shorter frames */
#define MAX_FRAME (HDR_BYTES + TEST_MTU)
#define SHORT_LAST 160
#define LENGTH_FRAMES (SHORT_LAST - HDR_BYTES + 1 + 3)
#define BURST_FRAMES 300
#define DRAIN_FRAMES 64
#define DRAIN_LENGTH 1514
#define FINAL_FRAMES 64
#define RCVBUF_BYTES (8 << 20)
#define STEP_MS 10000 /* sending and receiving one step's frames */
#define CARRIER_MS 5000
#define LOOPBACK_OFF_MS 2000
#define SETTLE_MS 2000
#define QUIET_MS 500
#define POLL_MS 50
#define RECV_TIMEOUT_MS 200
#define SEND_TIMEOUT_S 2

struct net_stats {
    uint64_t rx_packets;
    uint64_t tx_packets;
    uint64_t rx_errors;
    uint64_t tx_errors;
    uint64_t tx_dropped;
};

static char g_ifname[IFNAMSIZ];
static int g_ifindex;
static uint8_t g_mac[6];
static uint32_t g_run;
static uint32_t g_seq;  /* the next frame's sequence number; never reused */
static int g_ctl = -1;  /* ioctl socket */
static int g_sock = -1; /* the bound test socket */
static uint32_t g_feature_words;
static int g_loopback_bit = -1;
static char g_reason[256];
static uint8_t g_tx[MAX_FRAME];
static uint8_t g_want[MAX_FRAME];
static uint8_t g_rx[2 * MAX_FRAME];

static int fail(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void progress(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

/* Record the failure reason; returns -1 for the caller to pass up. */
static int fail(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_reason, sizeof(g_reason), fmt, ap);
    va_end(ap);
    return -1;
}

static void progress(const char *fmt, ...)
{
    char line[320];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    printf("FROST_NET_LOOPBACK: %s\n", line);
    fflush(stdout);
}

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t) ts.tv_sec * 1000u + (uint64_t) ts.tv_nsec / 1000000u;
}

static void sleep_ms(unsigned ms)
{
    struct timespec ts = {ms / 1000u, (long) (ms % 1000u) * 1000000L};
    nanosleep(&ts, NULL);
}

/* ---- interface control: ioctls on a socket that binds nothing ---- */

static void ifreq_init(struct ifreq *ifr, const char *name)
{
    memset(ifr, 0, sizeof(*ifr));
    snprintf(ifr->ifr_name, IFNAMSIZ, "%s", name);
}

static int ethtool_ioctl(const char *name, void *cmd)
{
    struct ifreq ifr;
    ifreq_init(&ifr, name);
    ifr.ifr_data = (char *) cmd;
    return ioctl(g_ctl, SIOCETHTOOL, &ifr);
}

static int find_interface(void)
{
    struct if_nameindex *names = if_nameindex();
    if (!names)
        return fail("if_nameindex: %s", strerror(errno));
    for (struct if_nameindex *p = names; p->if_index != 0; p++) {
        struct ethtool_drvinfo info;
        memset(&info, 0, sizeof(info));
        info.cmd = ETHTOOL_GDRVINFO;
        if (strlen(p->if_name) >= IFNAMSIZ || ethtool_ioctl(p->if_name, &info) != 0)
            continue;
        if (strncmp(info.driver, DRIVER_NAME, sizeof(info.driver)) == 0) {
            snprintf(g_ifname, sizeof(g_ifname), "%s", p->if_name);
            g_ifindex = (int) p->if_index;
            break;
        }
    }
    if_freenameindex(names);
    if (g_ifindex == 0)
        return fail("no interface with driver %s", DRIVER_NAME);

    struct ifreq ifr;
    ifreq_init(&ifr, g_ifname);
    if (ioctl(g_ctl, SIOCGIFHWADDR, &ifr) != 0)
        return fail("%s: SIOCGIFHWADDR: %s", g_ifname, strerror(errno));
    if (ifr.ifr_hwaddr.sa_family != ARPHRD_ETHER)
        return fail("%s: not an Ethernet address", g_ifname);
    memcpy(g_mac, ifr.ifr_hwaddr.sa_data, sizeof(g_mac));
    return 0;
}

static int set_up(int up)
{
    struct ifreq ifr;
    ifreq_init(&ifr, g_ifname);
    if (ioctl(g_ctl, SIOCGIFFLAGS, &ifr) != 0)
        return fail("%s: SIOCGIFFLAGS: %s", g_ifname, strerror(errno));
    ifr.ifr_flags = (short) (up ? (ifr.ifr_flags | IFF_UP) : (ifr.ifr_flags & ~IFF_UP));
    if (ioctl(g_ctl, SIOCSIFFLAGS, &ifr) != 0)
        return fail("%s: %s: %s", g_ifname, up ? "up" : "down", strerror(errno));
    return 0;
}

static int set_mtu(int mtu)
{
    struct ifreq ifr;
    ifreq_init(&ifr, g_ifname);
    ifr.ifr_mtu = mtu;
    if (ioctl(g_ctl, SIOCSIFMTU, &ifr) != 0)
        return fail("%s: mtu %d: %s", g_ifname, mtu, strerror(errno));
    ifreq_init(&ifr, g_ifname);
    if (ioctl(g_ctl, SIOCGIFMTU, &ifr) != 0)
        return fail("%s: SIOCGIFMTU: %s", g_ifname, strerror(errno));
    if (ifr.ifr_mtu != mtu)
        return fail("%s: mtu reads %d after setting %d", g_ifname, ifr.ifr_mtu, mtu);
    return 0;
}

/* The "loopback" bit from the ETH_SS_FEATURES strings, and the number of
 * feature words ETHTOOL_GFEATURES reports (ETHTOOL_SFEATURES wants it). */
static int find_loopback_bit(void)
{
    struct ethtool_sset_info *sset = calloc(1, sizeof(*sset) + sizeof(uint32_t));
    if (!sset)
        return fail("out of memory");
    sset->cmd = ETHTOOL_GSSET_INFO;
    sset->sset_mask = 1ull << ETH_SS_FEATURES;
    int rc = ethtool_ioctl(g_ifname, sset);
    int err = errno;
    uint32_t count = sset->data[0];
    int listed = (sset->sset_mask & (1ull << ETH_SS_FEATURES)) != 0;
    free(sset);
    if (rc != 0)
        return fail("ETHTOOL_GSSET_INFO: %s", strerror(err));
    if (!listed || count == 0)
        return fail("ETHTOOL_GSSET_INFO: no feature strings");

    struct ethtool_gstrings *strings =
        calloc(1, sizeof(*strings) + (size_t) count * ETH_GSTRING_LEN);
    if (!strings)
        return fail("out of memory");
    strings->cmd = ETHTOOL_GSTRINGS;
    strings->string_set = ETH_SS_FEATURES;
    strings->len = count;
    rc = ethtool_ioctl(g_ifname, strings);
    err = errno;
    int bit = -1;
    for (uint32_t i = 0; rc == 0 && strings->len == count && i < count; i++) {
        if (strncmp((const char *) strings->data + (size_t) i * ETH_GSTRING_LEN,
                    "loopback",
                    ETH_GSTRING_LEN) == 0) {
            bit = (int) i;
            break;
        }
    }
    uint32_t returned = strings->len;
    free(strings);
    if (rc != 0)
        return fail("ETHTOOL_GSTRINGS: %s", strerror(err));
    if (returned != count)
        return fail("ETHTOOL_GSTRINGS: %u feature strings, expected %u", returned, count);
    if (bit < 0)
        return fail("no \"loopback\" feature string");

    struct ethtool_gfeatures size_probe;
    memset(&size_probe, 0, sizeof(size_probe));
    size_probe.cmd = ETHTOOL_GFEATURES;
    if (ethtool_ioctl(g_ifname, &size_probe) != 0)
        return fail("ETHTOOL_GFEATURES: %s", strerror(errno));
    if ((uint32_t) bit >= size_probe.size * 32u)
        return fail("loopback bit %d beyond %u feature words", bit, size_probe.size);
    g_feature_words = size_probe.size;
    g_loopback_bit = bit;
    return 0;
}

static int get_loopback(int *available, int *requested, int *active)
{
    struct ethtool_gfeatures *gf =
        calloc(1, sizeof(*gf) + g_feature_words * sizeof(struct ethtool_get_features_block));
    if (!gf)
        return fail("out of memory");
    gf->cmd = ETHTOOL_GFEATURES;
    gf->size = g_feature_words;
    int rc = ethtool_ioctl(g_ifname, gf);
    int err = errno;
    const struct ethtool_get_features_block *block = &gf->features[g_loopback_bit / 32];
    uint32_t mask = 1u << (g_loopback_bit % 32);
    *available = (block->available & mask) != 0;
    *requested = (block->requested & mask) != 0;
    *active = (block->active & mask) != 0;
    free(gf);
    if (rc != 0)
        return fail("ETHTOOL_GFEATURES: %s", strerror(err));
    return 0;
}

/* The driver accepts a loopback change only while the interface is down; the
 * next up applies it. */
static int set_loopback(int on)
{
    int available, requested, active;
    if (get_loopback(&available, &requested, &active) != 0)
        return -1;
    if (!available)
        return on ? fail("%s does not offer the loopback feature", g_ifname) : 0;

    struct ethtool_sfeatures *sf =
        calloc(1, sizeof(*sf) + g_feature_words * sizeof(struct ethtool_set_features_block));
    if (!sf)
        return fail("out of memory");
    uint32_t mask = 1u << (g_loopback_bit % 32);
    sf->cmd = ETHTOOL_SFEATURES;
    sf->size = g_feature_words;
    sf->features[g_loopback_bit / 32].valid = mask;
    sf->features[g_loopback_bit / 32].requested = on ? mask : 0;
    int rc = ethtool_ioctl(g_ifname, sf);
    int err = errno;
    free(sf);
    if (rc < 0)
        return fail("loopback %s: %s", on ? "on" : "off", strerror(err));
    /* A positive result is a set of flags: the change was not made as asked
     * (ETHTOOL_F_WISH: recorded, but the driver refused it). */
    if (rc > 0)
        return fail("loopback %s: ETHTOOL_SFEATURES returned 0x%x:%s%s%s",
                    on ? "on" : "off",
                    rc,
                    (rc & ETHTOOL_F_UNSUPPORTED) ? " unsupported" : "",
                    (rc & ETHTOOL_F_WISH) ? " not applied" : "",
                    (rc & ETHTOOL_F_COMPAT) ? " compat" : "");
    if (get_loopback(&available, &requested, &active) != 0)
        return -1;
    if (requested != on || active != on)
        return fail("loopback %s: ETHTOOL_GFEATURES reads requested %d active %d",
                    on ? "on" : "off",
                    requested,
                    active);
    return 0;
}

/* ---- sysfs: carrier and the driver's statistics ---- */

static int read_sysfs_u64(const char *leaf, uint64_t *value)
{
    char path[96];
    char text[32];
    snprintf(path, sizeof(path), "/sys/class/net/%s/%s", g_ifname, leaf);
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return fail("%s: %s", path, strerror(errno));
    ssize_t n = read(fd, text, sizeof(text) - 1);
    int err = errno;
    close(fd);
    if (n <= 0)
        return fail("%s: %s", path, n < 0 ? strerror(err) : "empty");
    text[n] = '\0';
    char *end;
    *value = strtoull(text, &end, 10);
    if (end == text)
        return fail("%s: not a number", path);
    return 0;
}

static int read_stats(struct net_stats *s)
{
    if (read_sysfs_u64("statistics/rx_packets", &s->rx_packets) != 0 ||
        read_sysfs_u64("statistics/tx_packets", &s->tx_packets) != 0 ||
        read_sysfs_u64("statistics/rx_errors", &s->rx_errors) != 0 ||
        read_sysfs_u64("statistics/tx_errors", &s->tx_errors) != 0 ||
        read_sysfs_u64("statistics/tx_dropped", &s->tx_dropped) != 0)
        return -1;
    return 0;
}

/* The carrier must read 1 twice in a row. Reading it first runs the device's
 * pending link event (which activates the qdisc) and then samples the carrier,
 * so a carrier that NAPI raised in between reads 1 with the qdisc still
 * dropping every frame; the second read runs that event. */
static int wait_carrier(uint64_t *elapsed_ms)
{
    uint64_t start = now_ms();
    int ones = 0;
    for (;;) {
        uint64_t carrier;
        if (read_sysfs_u64("carrier", &carrier) != 0)
            return -1;
        *elapsed_ms = now_ms() - start;
        ones = carrier == 1 ? ones + 1 : 0;
        if (ones == 2)
            return 0;
        if (*elapsed_ms >= CARRIER_MS)
            return fail("%s: no carrier within %d ms", g_ifname, CARRIER_MS);
        if (ones == 0)
            sleep_ms(POLL_MS);
    }
}

/* Loopback off with the interface up for LOOPBACK_OFF_MS. The transceiver then
 * faces whatever it is cabled to, and a link partner may raise the carrier and
 * send frames, so nothing about the carrier is judged here. When the carrier
 * first read 1 is recorded for the progress line (UINT64_MAX: never). */
static int loopback_off_interval(uint64_t *carrier_ms)
{
    uint64_t start = now_ms();
    *carrier_ms = UINT64_MAX;
    for (;;) {
        uint64_t carrier;
        if (read_sysfs_u64("carrier", &carrier) != 0)
            return -1;
        uint64_t elapsed = now_ms() - start;
        if (carrier != 0 && *carrier_ms == UINT64_MAX)
            *carrier_ms = elapsed;
        if (elapsed >= LOOPBACK_OFF_MS)
            return 0;
        sleep_ms(POLL_MS);
    }
}

/* ---- the test socket ---- */

static void close_socket(void)
{
    if (g_sock >= 0)
        close(g_sock);
    g_sock = -1;
}

/* A fresh AF_PACKET socket for the test ethertype, bound to the interface
 * (which must be up: a bind while down leaves ENETDOWN pending). */
static int open_socket(void)
{
    struct timeval recv_timeout = {0, RECV_TIMEOUT_MS * 1000L};
    struct timeval send_timeout = {SEND_TIMEOUT_S, 0};
    struct sockaddr_ll addr;
    int one = 1;
    int rcvbuf = RCVBUF_BYTES;
    int granted = 0;
    socklen_t size = sizeof(granted);

    close_socket();
    g_sock = socket(AF_PACKET, SOCK_RAW, 0);
    if (g_sock < 0)
        return fail("packet socket: %s", strerror(errno));
    if (setsockopt(g_sock, SOL_PACKET, PACKET_IGNORE_OUTGOING, &one, sizeof(one)) != 0)
        return fail("PACKET_IGNORE_OUTGOING: %s", strerror(errno));
    /* A burst queues every frame at the RX buffer's size (about 16 KiB each at
     * MTU 9000) before the first receive. */
    if (setsockopt(g_sock, SOL_SOCKET, SO_RCVBUFFORCE, &rcvbuf, sizeof(rcvbuf)) != 0)
        return fail("SO_RCVBUFFORCE: %s", strerror(errno));
    if (getsockopt(g_sock, SOL_SOCKET, SO_RCVBUF, &granted, &size) != 0)
        return fail("SO_RCVBUF: %s", strerror(errno));
    if (granted < RCVBUF_BYTES)
        return fail("SO_RCVBUF reads %d after SO_RCVBUFFORCE %d", granted, RCVBUF_BYTES);
    if (setsockopt(g_sock, SOL_SOCKET, SO_RCVTIMEO, &recv_timeout, sizeof(recv_timeout)) != 0 ||
        setsockopt(g_sock, SOL_SOCKET, SO_SNDTIMEO, &send_timeout, sizeof(send_timeout)) != 0)
        return fail("socket timeouts: %s", strerror(errno));
    memset(&addr, 0, sizeof(addr));
    addr.sll_family = AF_PACKET;
    addr.sll_protocol = htons(ETHERTYPE_TEST);
    addr.sll_ifindex = g_ifindex;
    if (bind(g_sock, (struct sockaddr *) &addr, sizeof(addr)) != 0)
        return fail("bind to %s: %s", g_ifname, strerror(errno));
    return 0;
}

static int check_socket_drops(const char *what)
{
    struct tpacket_stats st;
    socklen_t size = sizeof(st);
    /* Reading the statistics resets them: each step counts its own drops. */
    if (getsockopt(g_sock, SOL_PACKET, PACKET_STATISTICS, &st, &size) != 0)
        return fail("%s: PACKET_STATISTICS: %s", what, strerror(errno));
    if (st.tp_drops != 0)
        return fail("%s: the socket dropped %u of %u frames", what, st.tp_drops, st.tp_packets);
    return 0;
}

/* ---- frames ---- */

static void put_le32(uint8_t *p, uint32_t v)
{
    for (int i = 0; i < 4; i++)
        p[i] = (uint8_t) (v >> (8 * i));
}

static uint32_t get_le32(const uint8_t *p)
{
    return (uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16) |
           ((uint32_t) p[3] << 24);
}

/* Frame seq of length len: the interface's address as destination and source,
 * the test ethertype, the tag, then bytes from a generator seeded by run and
 * sequence. The tag leads with the sequence number's low byte, so a frame that
 * holds any of the tag differs from its neighbours. */
static void build_frame(uint8_t *frame, uint32_t seq, uint32_t len)
{
    uint8_t head[HDR_BYTES + TAG_BYTES];
    memcpy(head, g_mac, 6);
    memcpy(head + 6, g_mac, 6);
    head[12] = (uint8_t) (ETHERTYPE_TEST >> 8);
    head[13] = (uint8_t) ETHERTYPE_TEST;
    put_le32(head + 14, seq);
    put_le32(head + 18, g_run);
    head[22] = (uint8_t) len;
    head[23] = (uint8_t) (len >> 8);
    uint32_t x = g_run ^ (seq * 2654435761u);
    for (uint32_t i = 0; i < len; i++) {
        if (i < sizeof(head)) {
            frame[i] = head[i];
        } else {
            x = x * 1664525u + 1013904223u;
            frame[i] = (uint8_t) (x >> 24);
        }
    }
}

static int send_frame(uint32_t seq, uint32_t len, const char *what)
{
    build_frame(g_tx, seq, len);
    ssize_t n = send(g_sock, g_tx, len, 0);
    if (n < 0)
        return fail("%s: send frame %u (%u bytes): %s", what, seq, len, strerror(errno));
    if ((size_t) n != len)
        return fail("%s: send frame %u: %zd of %u bytes", what, seq, n, len);
    return 0;
}

/* Name what arrived instead of frame seq (whose image is in g_want): a frame
 * of this run with another sequence number, a wrong length, or the first
 * differing byte. */
static int describe_mismatch(uint32_t seq, uint32_t len, ssize_t n, const char *what)
{
    uint32_t want = len < MIN_FRAME ? MIN_FRAME : len;
    if (n > (ssize_t) sizeof(g_rx))
        return fail("%s: frame %u: received a %zd-byte frame", what, seq, n);
    /* A frame of this run names itself by its sequence number (no byte of the
     * run identifier is zero, so zero padding does not pass for one). */
    if (n >= HDR_BYTES + TAG_BYTES && get_le32(g_rx + 18) == g_run) {
        uint32_t got = get_le32(g_rx + 14);
        if (got < seq)
            return fail(
                "%s: expected frame %u, received frame %u (stale or duplicate)", what, seq, got);
        if (got > seq)
            return fail(
                "%s: expected frame %u, received frame %u (lost or reordered)", what, seq, got);
    }
    if ((uint32_t) n != want)
        return fail("%s: frame %u (%u bytes sent): received %zd bytes, expected %u",
                    what,
                    seq,
                    len,
                    n,
                    want);
    for (uint32_t i = 0; i < len; i++)
        if (g_rx[i] != g_want[i])
            return fail("%s: frame %u (%u bytes): byte %u reads 0x%02x, expected 0x%02x",
                        what,
                        seq,
                        len,
                        i,
                        g_rx[i],
                        g_want[i]);
    return fail("%s: frame %u: mismatch", what, seq);
}

/* The next frame must be frame seq: max(len, 60) bytes whose first len bytes
 * are the ones sent (the MAC's padding is not checked). */
static int receive_frame(uint32_t seq, uint32_t len, uint64_t deadline, const char *what)
{
    ssize_t n;
    for (;;) {
        if (now_ms() >= deadline)
            return fail("%s: frame %u (%u bytes) not received in time", what, seq, len);
        n = recv(g_sock, g_rx, sizeof(g_rx), MSG_TRUNC);
        if (n >= 0)
            break;
        if (errno != EAGAIN && errno != EINTR)
            return fail("%s: recv: %s", what, strerror(errno));
    }
    uint32_t want = len < MIN_FRAME ? MIN_FRAME : len;
    build_frame(g_want, seq, len);
    if ((uint32_t) n == want && memcmp(g_rx, g_want, len) == 0)
        return 0;
    return describe_mismatch(seq, len, n, what);
}

/* Step 3's lengths: every length from the bare header to 160 bytes, then
 * three large frames up to the MTU. */
static uint32_t length_at(unsigned i)
{
    static const uint32_t large[] = {1514, 4096, MAX_FRAME};
    unsigned shorts = SHORT_LAST - HDR_BYTES + 1;
    return i < shorts ? HDR_BYTES + i : large[i - shorts];
}

/* Burst lengths spread over 60..1514, so buffer contents and byte positions
 * change from one ring slot to the next. */
static uint32_t burst_length(unsigned i)
{
    return MIN_FRAME + (i * 389u) % (1514u - MIN_FRAME + 1u);
}

static int lengths_step(void)
{
    uint64_t deadline = now_ms() + STEP_MS;
    for (unsigned i = 0; i < LENGTH_FRAMES; i++) {
        uint32_t seq = g_seq++;
        if (send_frame(seq, length_at(i), "lengths") != 0 ||
            receive_frame(seq, length_at(i), deadline, "lengths") != 0)
            return -1;
    }
    return check_socket_drops("lengths");
}

/* Send count frames, then receive them in order. */
static int burst(unsigned count, const char *what)
{
    uint32_t first = g_seq;
    uint64_t deadline = now_ms() + STEP_MS;
    for (unsigned i = 0; i < count; i++) {
        if (now_ms() >= deadline)
            return fail("%s: %u of %u frames sent in %d ms", what, i, count, STEP_MS);
        if (send_frame(g_seq++, burst_length(i), what) != 0)
            return -1;
    }
    for (unsigned i = 0; i < count; i++)
        if (receive_frame(first + i, burst_length(i), deadline, what) != 0)
            return -1;
    return check_socket_drops(what);
}

/* After a verified step: wait (bounded) until the driver's counters cover its
 * frames, since TX completions are counted when reaped and can trail the last
 * receive, then require that no further frame (a duplicate) arrives for
 * QUIET_MS. Step 6 judges the counters. */
static int
settle(const struct net_stats *start, unsigned frames, struct net_stats *end, const char *what)
{
    uint64_t deadline = now_ms() + SETTLE_MS;
    for (;;) {
        if (read_stats(end) != 0)
            return -1;
        if (end->tx_packets >= start->tx_packets + frames &&
            end->rx_packets >= start->rx_packets + frames)
            break;
        if (now_ms() >= deadline)
            break;
        sleep_ms(POLL_MS);
    }
    uint64_t quiet_end = now_ms() + QUIET_MS;
    while (now_ms() < quiet_end) {
        ssize_t n = recv(g_sock, g_rx, sizeof(g_rx), MSG_TRUNC);
        if (n >= HDR_BYTES + TAG_BYTES && get_le32(g_rx + 18) == g_run)
            return fail("%s: an extra frame %u arrived", what, get_le32(g_rx + 14));
        if (n >= 0)
            return fail("%s: an extra %zd-byte frame arrived", what, n);
        if (errno != EAGAIN && errno != EINTR)
            return fail("%s: recv: %s", what, strerror(errno));
    }
    /* Anything the driver counted meanwhile (an error it dropped) belongs to
     * the step as well. */
    return read_stats(end);
}

static int check_window(const char *what,
                        const struct net_stats *start,
                        const struct net_stats *end,
                        unsigned frames)
{
    if (end->tx_packets < start->tx_packets + frames ||
        end->rx_packets < start->rx_packets + frames)
        return fail("statistics: %s: tx_packets %+lld rx_packets %+lld for %u frames",
                    what,
                    (long long) (end->tx_packets - start->tx_packets),
                    (long long) (end->rx_packets - start->rx_packets),
                    frames);
    return 0;
}

/* Between two snapshots nothing was sent: no frame may be counted in either
 * direction, no error may appear, and no counter may restart. */
static int check_idle(const char *what, const struct net_stats *start, const struct net_stats *end)
{
    if (end->tx_packets != start->tx_packets || end->rx_packets != start->rx_packets ||
        end->rx_errors != start->rx_errors || end->tx_errors != start->tx_errors)
        return fail("statistics %s: tx_packets %+lld rx_packets %+lld rx_errors %+lld "
                    "tx_errors %+lld with nothing sent",
                    what,
                    (long long) (end->tx_packets - start->tx_packets),
                    (long long) (end->rx_packets - start->rx_packets),
                    (long long) (end->rx_errors - start->rx_errors),
                    (long long) (end->tx_errors - start->tx_errors));
    return 0;
}

static int run(void)
{
    struct net_stats start, a0, a1, d0, d1, e1, b0, b1;
    uint64_t carrier_ms = 0;
    uint64_t off_carrier_ms = UINT64_MAX;
    char off_carrier[48];
    unsigned window_a = LENGTH_FRAMES + BURST_FRAMES;

    /* ---- Step 1: the driver's interface, down ---- */
    g_ctl = socket(AF_PACKET, SOCK_DGRAM, 0);
    if (g_ctl < 0)
        return fail("control socket: %s", strerror(errno));
    if (find_interface() != 0 || find_loopback_bit() != 0 || set_up(0) != 0 ||
        read_stats(&start) != 0)
        return -1;
    progress("%s: driver %s, address %02x:%02x:%02x:%02x:%02x:%02x, loopback feature bit %d, "
             "run %08x; down",
             g_ifname,
             DRIVER_NAME,
             g_mac[0],
             g_mac[1],
             g_mac[2],
             g_mac[3],
             g_mac[4],
             g_mac[5],
             g_loopback_bit,
             g_run);

    /* ---- Step 2: MTU and loopback while down, then up ---- */
    if (set_mtu(TEST_MTU) != 0 || set_loopback(1) != 0 || set_up(1) != 0 ||
        wait_carrier(&carrier_ms) != 0 || open_socket() != 0)
        return -1;
    progress("mtu %d, loopback on, up: carrier after %llu ms",
             TEST_MTU,
             (unsigned long long) carrier_ms);

    /* ---- Step 3: lengths, one frame at a time ---- */
    if (read_stats(&a0) != 0 || check_idle("before the first frame", &start, &a0) != 0 ||
        lengths_step() != 0)
        return -1;
    progress("lengths %d..%d, 1514, 4096, %d: %d frames verified",
             HDR_BYTES,
             SHORT_LAST,
             MAX_FRAME,
             LENGTH_FRAMES);

    /* ---- Step 4: a burst larger than both rings ---- */
    if (burst(BURST_FRAMES, "burst") != 0 || settle(&a0, window_a, &a1, "burst") != 0)
        return -1;
    progress("burst of %d sent before receiving: in order, no socket drops", BURST_FRAMES);

    /* ---- Step 5: down during a burst; loopback off; loopback on again ---- */
    if (read_stats(&d0) != 0)
        return -1;
    uint64_t drain_deadline = now_ms() + STEP_MS;
    for (unsigned i = 0; i < DRAIN_FRAMES; i++) {
        if (now_ms() >= drain_deadline)
            return fail("drain: %u of %d frames sent in %d ms", i, DRAIN_FRAMES, STEP_MS);
        if (send_frame(g_seq++, DRAIN_LENGTH, "drain") != 0)
            return -1;
    }
    if (set_up(0) != 0 || read_stats(&d1) != 0)
        return -1;
    close_socket();
    /* The loopback-off interval ends at the down after it: e1 starts the
     * statistics again, so what a link partner sent meanwhile counts nowhere. */
    if (set_loopback(0) != 0 || set_up(1) != 0 || loopback_off_interval(&off_carrier_ms) != 0 ||
        set_up(0) != 0 || read_stats(&e1) != 0)
        return -1;
    if (set_loopback(1) != 0 || set_up(1) != 0 || wait_carrier(&carrier_ms) != 0 ||
        open_socket() != 0 || read_stats(&b0) != 0 ||
        check_idle("between loopback on and the last burst", &e1, &b0) != 0)
        return -1;
    if (burst(FINAL_FRAMES, "after the drain") != 0 ||
        settle(&b0, FINAL_FRAMES, &b1, "after the drain") != 0)
        return -1;
    if (off_carrier_ms == UINT64_MAX)
        snprintf(off_carrier, sizeof(off_carrier), "no carrier");
    else
        snprintf(off_carrier,
                 sizeof(off_carrier),
                 "carrier after %llu ms",
                 (unsigned long long) off_carrier_ms);
    progress("drain: %d sent, then down (tx_dropped %+lld, rx_packets %+lld); loopback off, up "
             "for %d ms (%s, not judged); loopback on, up: %d frames verified",
             DRAIN_FRAMES,
             (long long) (d1.tx_dropped - d0.tx_dropped),
             (long long) (d1.rx_packets - d0.rx_packets),
             LOOPBACK_OFF_MS,
             off_carrier,
             FINAL_FRAMES);

    /* ---- Step 6: the driver's statistics, loopback-off interval excluded ---- */
    if (check_window("steps 3-4", &a0, &a1, window_a) != 0 ||
        check_window("step 5", &b0, &b1, FINAL_FRAMES) != 0)
        return -1;
    uint64_t rx_errors = (d1.rx_errors - start.rx_errors) + (b1.rx_errors - e1.rx_errors);
    uint64_t tx_errors = (d1.tx_errors - start.tx_errors) + (b1.tx_errors - e1.tx_errors);
    if (rx_errors != 0 || tx_errors != 0)
        return fail("statistics: rx_errors %+lld tx_errors %+lld with loopback on",
                    (long long) rx_errors,
                    (long long) tx_errors);
    progress("statistics: tx_packets %+lld rx_packets %+lld for %d verified frames; "
             "rx_errors and tx_errors unchanged with loopback on",
             (long long) ((a1.tx_packets - a0.tx_packets) + (b1.tx_packets - b0.tx_packets)),
             (long long) ((a1.rx_packets - a0.rx_packets) + (b1.rx_packets - b0.rx_packets)),
             LENGTH_FRAMES + BURST_FRAMES + FINAL_FRAMES);

    /* ---- Step 7: leave the interface down with loopback off ---- */
    close_socket();
    if (set_up(0) != 0 || set_loopback(0) != 0)
        return -1;
    progress("%s down, loopback off", g_ifname);
    return 0;
}

/* After a failure: step 7 as far as the failure allows. Returns 1 when the
 * interface is down with loopback off, 0 when no interface was found, -1 when
 * that state could not be reached (the reason is in g_reason). */
static int restore(void)
{
    close_socket();
    if (g_ifindex == 0)
        return 0;
    if (set_up(0) != 0)
        return -1;
    if (g_loopback_bit < 0 && find_loopback_bit() != 0)
        return -1;
    return set_loopback(0) != 0 ? -1 : 1;
}

int main(void)
{
    struct timespec ts;
    setvbuf(stdout, NULL, _IOLBF, 0);
    clock_gettime(CLOCK_MONOTONIC, &ts);
    /* Every byte nonzero, so zero padding never reads as this run's tag. */
    g_run =
        ((uint32_t) ts.tv_nsec ^ (uint32_t) ts.tv_sec ^ ((uint32_t) getpid() << 12)) | 0x01010101u;
    /* Sequence numbers start from the run identifier, so an earlier run's
     * short frames are unlikely to repeat this run's; the top bit stays clear
     * so a run never wraps. */
    g_seq = (g_run * 2654435761u) & 0x7fffffffu;

    if (run() == 0) {
        printf("FROST_NET_LOOPBACK_PASS\n");
        fflush(stdout);
        return 0;
    }
    char reason[sizeof(g_reason)];
    memcpy(reason, g_reason, sizeof(reason));
    int restored = restore();
    if (restored > 0)
        progress("%s down, loopback off", g_ifname);
    if (restored < 0)
        printf("FROST_NET_LOOPBACK_FAIL %s (restoring the interface: %s)\n", reason, g_reason);
    else
        printf("FROST_NET_LOOPBACK_FAIL %s\n", reason);
    fflush(stdout);
    return 1;
}
