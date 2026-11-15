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
 * frost_nettest: tests the frost,net10g driver through its loopback feature.
 *
 * Select the interface whose ETHTOOL_GDRVINFO driver is frost_net10g. Loopback
 * uses the NIC MAC when both directions share a clock, or the transceiver PMA
 * otherwise. Check frame contents, order, socket drops, and driver counters.
 * Exclude the loopback-off interval from idle and error checks because a link
 * partner may send traffic. Leave the interface down with loopback off, even
 * on failure, and print:
 *
 *   FROST_NET_LOOPBACK_PASS
 *   FROST_NET_LOOPBACK_FAIL <reason>
 *
 * AF_PACKET frames use the interface's own address at both ends and ethertype
 * 0x88B5. Rebind after each up: a down leaves ENETDOWN pending on bound sockets.
 * Tags hold a sequence unique within the run, a run identifier, and a length
 * to detect lost, duplicate, reordered, stale, or corrupt frames. Run identifiers
 * can collide. Frames below 24 bytes have partial tags (14-byte frames have
 * none); check their sent bytes and padded length. After each verified burst,
 * no further frame may arrive for half a second.
 *
 * Every wait the program makes is bounded (one step's frames get 10 s); a
 * system call that never returns is left to the caller's timeout. The test
 * uses no IP: all control goes through ioctls and sysfs. Sysfs descriptors
 * are opened before taking the link down, so reads do not traverse an NFS root.
 * FROST_NETTEST_EXPIRE_NFS_CACHE=1 holds the interface down for 65 seconds
 * before reading counters, exceeding NFS's default directory attribute lifetime.
 *
 * A second packet socket captures every frame of the interface for the whole
 * run. Before each window's verdict the test lists the frames of that window
 * that are not its own ("foreign frame" lines) and a "capture" summary; these
 * lines never change a verdict. FROST_NETTEST_REPETITION=r/n marks the run as
 * repetition r of n in one boot: repetitions before the last print their
 * verdicts as FROST_NET_DIAG_PASS or FROST_NET_DIAG_FAIL rep=r <reason>.
 * --selftest checks the frame decoder on synthetic frames and needs no NIC.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/ethtool.h>
#include <linux/if_ether.h>
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
#define NORMAL_MTU 1500
#define NORMAL_FRAMES 600
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
static int g_sysfs = -1;
static int g_expire_nfs_cache;
enum { RX_PACKETS, TX_PACKETS, RX_ERRORS, TX_ERRORS, TX_DROPPED, CARRIER };
static struct {
    const char *leaf;
    int fd;
} g_attrs[] = {{"statistics/rx_packets", -1},
               {"statistics/tx_packets", -1},
               {"statistics/rx_errors", -1},
               {"statistics/tx_errors", -1},
               {"statistics/tx_dropped", -1},
               {"carrier", -1}};
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

static const char *g_requested_ifname;

static int find_interface(void)
{
    struct if_nameindex *names = if_nameindex();
    if (!names)
        return fail("if_nameindex: %s", strerror(errno));
    for (struct if_nameindex *p = names; p->if_index != 0; p++) {
        if (g_requested_ifname && strcmp(p->if_name, g_requested_ifname) != 0)
            continue;
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

/* Keep the directory and attributes open until exit, including on failure. */
static int open_sysfs(void)
{
    char path[96];
    snprintf(path, sizeof(path), "/sys/class/net/%s", g_ifname);
    g_sysfs = open(path, O_RDONLY | O_DIRECTORY);
    if (g_sysfs < 0)
        return fail("%s: %s", path, strerror(errno));
    for (unsigned i = 0; i < sizeof(g_attrs) / sizeof(g_attrs[0]); i++) {
        g_attrs[i].fd = openat(g_sysfs, g_attrs[i].leaf, O_RDONLY);
        if (g_attrs[i].fd < 0)
            return fail("%s/%s: %s", path, g_attrs[i].leaf, strerror(errno));
    }
    return 0;
}

static int read_sysfs_u64(unsigned attr, uint64_t *value)
{
    char path[96];
    char text[32];
    snprintf(path, sizeof(path), "/sys/class/net/%s/%s", g_ifname, g_attrs[attr].leaf);
    int fd = g_attrs[attr].fd;
    if (lseek(fd, 0, SEEK_SET) < 0)
        return fail("%s: %s", path, strerror(errno));
    ssize_t n = read(fd, text, sizeof(text) - 1);
    int err = errno;
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
    if (read_sysfs_u64(RX_PACKETS, &s->rx_packets) != 0 ||
        read_sysfs_u64(TX_PACKETS, &s->tx_packets) != 0 ||
        read_sysfs_u64(RX_ERRORS, &s->rx_errors) != 0 ||
        read_sysfs_u64(TX_ERRORS, &s->tx_errors) != 0 ||
        read_sysfs_u64(TX_DROPPED, &s->tx_dropped) != 0)
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
        if (read_sysfs_u64(CARRIER, &carrier) != 0)
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

/* Observe carrier for LOOPBACK_OFF_MS with loopback off. A link partner may
 * raise it or send frames, so record the first rise without judging it
 * (UINT64_MAX means none). */
static int loopback_off_interval(uint64_t *carrier_ms)
{
    uint64_t start = now_ms();
    *carrier_ms = UINT64_MAX;
    for (;;) {
        uint64_t carrier;
        if (read_sysfs_u64(CARRIER, &carrier) != 0)
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

/* ---- tag fields ---- */

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

/* ---- the capture socket: every frame of the interface, for diagnosis ---- */

/* A second packet socket for all protocols, bound to the interface once it is
 * known and kept open for the whole run. A down unhooks it and leaves ENETDOWN
 * pending, which the next receive returns once before any queued frame; the
 * socket stays bound and the next up hooks it again. It sees each frame the
 * stack hands the driver (sll_pkttype PACKET_OUTGOING, "out") and each frame
 * the driver passes up ("in"), so a looped-back frame the stack sent appears
 * twice, out then in; a frame the hardware made up or repeated appears only
 * in, and one the stack sent that never came back appears only out.
 *
 * At the end of every window the test judges, drain it and list, before that
 * window's verdict, each frame that is not one of the test's own frames sent
 * in that window: a test frame of an earlier window ("stale test frame"), a
 * second copy of one, a test frame of another run, or any other frame. Each
 * listed frame takes two lines (Ethernet header, then the decoded payload) so
 * every line stays under about 150 characters. A summary line per window
 * gives the counts and the socket's drops. Nothing here changes a verdict. */

#define CAPTURE_RCVBUF_BYTES (32 << 20) /* a window's own frames, both copies */
#define CAPTURE_SNAP 192                /* Ethernet, VLAN, IPv4 and TCP headers */
#define CAPTURE_LINES 12                /* foreign frames listed per window */
#define CAPTURE_MAX_FRAMES 100000       /* bounds one drain */
#define CAPTURE_STRAGGLER_MS 100        /* before draining a window that failed */
#define CAPTURE_SEEN 2048               /* duplicate detection, frames per window */
#define CAPTURE_SHORTS 32               /* frames under a whole tag, per window */
#define FOREIGN_LINE 200

static int g_cap = -1;
static int64_t g_t0_us; /* CLOCK_REALTIME at start: frame timestamps use it */
static int64_t g_window_start_us;
static const char *g_window = "pre"; /* the window the capture is in */
static uint32_t g_window_seq;        /* the first sequence number of the window */
static uint8_t g_seen[2][CAPTURE_SEEN / 8];
static struct {
    uint32_t seq, len;
} g_shorts[CAPTURE_SHORTS];
static unsigned g_nshorts;

static void build_frame(uint8_t *frame, uint32_t seq, uint32_t len);

/* Frames shorter than a whole tag cannot name their run, and the MAC pads the
 * received copy: remember them so their copies are still recognised. */
static void capture_note_sent(uint32_t seq, uint32_t len)
{
    if (len < HDR_BYTES + TAG_BYTES && g_nshorts < CAPTURE_SHORTS) {
        g_shorts[g_nshorts].seq = seq;
        g_shorts[g_nshorts].len = len;
        g_nshorts++;
    }
}

static int64_t realtime_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t) ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static void format_mac(char *out, const uint8_t *m)
{
    snprintf(out, 18, "%02x:%02x:%02x:%02x:%02x:%02x", m[0], m[1], m[2], m[3], m[4], m[5]);
}

static void format_ip(char *out, const uint8_t *p)
{
    snprintf(out, 16, "%u.%u.%u.%u", p[0], p[1], p[2], p[3]);
}

static unsigned get_be16(const uint8_t *p)
{
    return ((unsigned) p[0] << 8) | p[1];
}

static uint32_t get_be32(const uint8_t *p)
{
    return ((uint32_t) p[0] << 24) | ((uint32_t) p[1] << 16) | ((uint32_t) p[2] << 8) | p[3];
}

/* Whether a copy of this window's frame seq was already seen this way. */
static int seen(int out, uint32_t seq)
{
    uint32_t k = seq - g_window_seq;
    return seq >= g_window_seq && k < CAPTURE_SEEN && (g_seen[out][k / 8] & (1u << (k % 8)));
}

enum frame_class {
    FRAME_OWN,       /* a test frame sent in this window, first copy this way */
    FRAME_DUPLICATE, /* a second copy of one, the same way */
    FRAME_STALE,     /* this run's test frame sent in an earlier window */
    FRAME_AHEAD,     /* this run's identifier with a sequence not yet sent */
    FRAME_OTHER_RUN, /* the test's header and a whole tag of another run */
    FRAME_PARTIAL,   /* the test's header, a tag too short to name a run */
    FRAME_FOREIGN,   /* anything else */
};

/* Classify a frame of len bytes whose first cap are in f (out: 1 for the
 * outgoing copy). The test's frames carry the test ethertype with the
 * interface's address at both ends; seq returns the tag's sequence. */
static enum frame_class classify(const uint8_t *f, size_t cap, size_t len, int out, uint32_t *seq)
{
    *seq = 0;
    if (cap < HDR_BYTES || get_be16(f + 12) != ETHERTYPE_TEST || memcmp(f, g_mac, 6) != 0 ||
        memcmp(f + 6, g_mac, 6) != 0)
        return FRAME_FOREIGN;
    /* A whole tag names its own length: the frame's, or a length from 24 to
     * 59 bytes that the MAC padded to the minimum. */
    size_t tag_len = cap >= HDR_BYTES + TAG_BYTES ? (size_t) f[22] | ((size_t) f[23] << 8) : 0;
    if (tag_len == len ||
        (len == MIN_FRAME && tag_len >= HDR_BYTES + TAG_BYTES && tag_len < MIN_FRAME)) {
        *seq = get_le32(f + 14);
        if (get_le32(f + 18) != g_run)
            return FRAME_OTHER_RUN;
    } else {
        /* No whole tag: one of this window's short frames, its bytes at the
         * length sent (the outgoing copy) or padded to the minimum (the
         * received one). A padded copy also matches every shorter frame (a
         * 14-byte frame carries no tag and matches any), so take the longest
         * match not yet seen this way; only when every match has been seen
         * is the frame a duplicate. */
        int best = -1, best_unseen = -1;
        for (unsigned i = 0; i < g_nshorts; i++) {
            uint8_t want[HDR_BYTES + TAG_BYTES];
            uint32_t slen = g_shorts[i].len;
            if (len != slen && !(len == MIN_FRAME && !out))
                continue;
            build_frame(want, g_shorts[i].seq, slen);
            if (cap < slen || memcmp(f, want, slen) != 0)
                continue;
            if (best < 0 || slen > g_shorts[best].len)
                best = (int) i;
            if (!seen(out, g_shorts[i].seq) &&
                (best_unseen < 0 || slen > g_shorts[best_unseen].len))
                best_unseen = (int) i;
        }
        if (best < 0)
            return FRAME_PARTIAL;
        *seq = g_shorts[best_unseen >= 0 ? best_unseen : best].seq;
    }
    if (*seq < g_window_seq)
        return FRAME_STALE;
    if (*seq >= g_seq)
        return FRAME_AHEAD;
    uint32_t k = *seq - g_window_seq;
    if (k < CAPTURE_SEEN) {
        uint8_t bit = (uint8_t) (1u << (k % 8));
        if (g_seen[out][k / 8] & bit)
            return FRAME_DUPLICATE;
        g_seen[out][k / 8] |= bit;
    }
    return FRAME_OWN;
}

/* The decoded payload of a frame of type type at p (pcap bytes captured, plen
 * long): ARP, IPv4 with TCP, UDP or ICMP, else its first 24 bytes in hex. */
static void
decode_payload(char *out, size_t size, unsigned type, const uint8_t *p, size_t pcap, size_t plen)
{
    char a[16], b[16];

    if (type == 0x0806 && pcap >= 28 && get_be16(p) == 1 && get_be16(p + 2) == 0x0800 &&
        p[4] == 6 && p[5] == 4) {
        unsigned op = get_be16(p + 6);
        format_ip(a, p + 14);
        format_ip(b, p + 24);
        if (op == 1 || op == 2)
            snprintf(out, size, "arp %s spa=%s tpa=%s", op == 1 ? "request" : "reply", a, b);
        else
            snprintf(out, size, "arp op=%u spa=%s tpa=%s", op, a, b);
        return;
    }
    if (type == 0x0800 && pcap >= 20 && (p[0] >> 4) == 4 && (p[0] & 15) >= 5) {
        size_t ihl = (size_t) (p[0] & 15) * 4;
        unsigned total = get_be16(p + 2);
        unsigned frag = get_be16(p + 6) & 0x1fffu;
        unsigned proto = p[9];
        format_ip(a, p + 12);
        format_ip(b, p + 16);
        if (frag == 0 && proto == 6 && pcap >= ihl + 20) {
            const uint8_t *t = p + ihl;
            long doff = (long) (t[12] >> 4) * 4;
            static const char names[] = "FSRPAUEC";
            char flags[9];
            unsigned k = 0;
            for (unsigned i = 0; i < 8; i++)
                if (t[13] & (1u << i))
                    flags[k++] = names[i];
            flags[k] = '\0';
            snprintf(out,
                     size,
                     "tcp %s:%u>%s:%u %s seq=%u ack=%u pl=%ld",
                     a,
                     get_be16(t),
                     b,
                     get_be16(t + 2),
                     k ? flags : "-",
                     get_be32(t + 4),
                     get_be32(t + 8),
                     (long) total - (long) ihl - doff);
            return;
        }
        if (frag == 0 && proto == 17 && pcap >= ihl + 8) {
            const uint8_t *u = p + ihl;
            snprintf(out,
                     size,
                     "udp %s:%u>%s:%u pl=%ld",
                     a,
                     get_be16(u),
                     b,
                     get_be16(u + 2),
                     (long) get_be16(u + 4) - 8);
            return;
        }
        if (frag == 0 && proto == 1 && pcap >= ihl + 2) {
            snprintf(out, size, "icmp %s>%s type=%u code=%u", a, b, p[ihl], p[ihl + 1]);
            return;
        }
        snprintf(
            out, size, "ipv4 proto=%u %s>%s len=%u%s", proto, a, b, total, frag ? " fragment" : "");
        return;
    }
    size_t n = plen < 24 ? plen : 24;
    if (n > pcap)
        n = pcap;
    size_t used = (size_t) snprintf(out, size, "data=");
    for (size_t i = 0; i < n && used + 3 <= size; i++)
        used += (size_t) snprintf(out + used, size - used, "%02x", p[i]);
}

/* The second line's text: what the frame is. */
static void describe_frame(char *out,
                           size_t size,
                           enum frame_class c,
                           uint32_t seq,
                           const uint8_t *f,
                           size_t cap,
                           size_t len)
{
    switch (c) {
        case FRAME_STALE:
            snprintf(out, size, "stale test frame seq=%u (this window from %u)", seq, g_window_seq);
            return;
        case FRAME_DUPLICATE:
            snprintf(out, size, "duplicate test frame seq=%u", seq);
            return;
        case FRAME_AHEAD:
            snprintf(out, size, "test frame seq=%u not sent yet (next %u)", seq, g_seq);
            return;
        case FRAME_OTHER_RUN:
            snprintf(out, size, "test frame of run %08x seq=%u", get_le32(f + 18), seq);
            return;
        case FRAME_PARTIAL:
        case FRAME_FOREIGN:
        case FRAME_OWN:
            break;
    }
    unsigned type = get_be16(f + 12);
    size_t off = HDR_BYTES;
    char vlan[24] = "";
    if ((type == 0x8100 || type == 0x88a8) && cap >= HDR_BYTES + 4) {
        snprintf(vlan, sizeof(vlan), "tag vlan=%u ", get_be16(f + 14) & 0xfffu);
        type = get_be16(f + 16);
        off += 4;
    }
    char decoded[128];
    decode_payload(decoded, sizeof(decoded), type, f + off, cap - off, len - off);
    snprintf(out,
             size,
             "%s%s%s",
             vlan,
             c == FRAME_PARTIAL ? "test frame without a whole tag " : "",
             decoded);
}

/* The two lines of a listed frame, without newlines. vlan is the tag the
 * kernel took off a received frame, or -1. */
static void format_foreign(char *line1,
                           char *line2,
                           size_t size,
                           const char *window,
                           unsigned index,
                           const char *dir,
                           enum frame_class c,
                           uint32_t seq,
                           const uint8_t *f,
                           size_t cap,
                           size_t len,
                           int vlan,
                           long long t_ms)
{
    char dst[18], src[18], tag[16] = "", when[24], what[160];
    if (t_ms >= 0 && t_ms < 100000000)
        snprintf(when, sizeof(when), "t=%lld", t_ms);
    else
        snprintf(when, sizeof(when), "t=?");
    if (cap < HDR_BYTES) {
        snprintf(line1,
                 size,
                 "foreign frame %s #%u dir=%s len=%zu runt %s",
                 window,
                 index,
                 dir,
                 len,
                 when);
        snprintf(line2, size, "foreign frame %s #%u runt", window, index);
        return;
    }
    if (vlan >= 0)
        snprintf(tag, sizeof(tag), " vlan=%d", vlan);
    format_mac(dst, f);
    format_mac(src, f + 6);
    snprintf(line1,
             size,
             "foreign frame %s #%u dir=%s len=%zu dst=%s src=%s type=0x%04x%s %s",
             window,
             index,
             dir,
             len,
             dst,
             src,
             get_be16(f + 12),
             tag,
             when);
    describe_frame(what, sizeof(what), c, seq, f, cap, len);
    snprintf(line2, size, "foreign frame %s #%u %s", window, index, what);
}

/* Start the window named next: its own frames are the ones sent from now. */
static void capture_start(const char *next, int64_t now_us)
{
    g_window = next;
    g_window_start_us = now_us;
    g_window_seq = g_seq;
    g_nshorts = 0;
    memset(g_seen, 0, sizeof(g_seen));
}

static void open_capture(void)
{
    struct sockaddr_ll addr;
    int rcvbuf = CAPTURE_RCVBUF_BYTES;
    int granted = 0;
    socklen_t size = sizeof(granted);
    int one = 1;
    const char *step = "packet socket";

    /* Protocol 0 until the bind, so no frame of another interface queues. */
    g_cap = socket(AF_PACKET, SOCK_RAW | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (g_cap >= 0) {
        /* Without the privilege to exceed rmem_max, take what SO_RCVBUF gives:
         * the drop count says whether it was enough. */
        if (setsockopt(g_cap, SOL_SOCKET, SO_RCVBUFFORCE, &rcvbuf, sizeof(rcvbuf)) != 0)
            setsockopt(g_cap, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
        if (getsockopt(g_cap, SOL_SOCKET, SO_RCVBUF, &granted, &size) != 0)
            granted = -1;
        step = "SO_TIMESTAMPNS";
        if (setsockopt(g_cap, SOL_SOCKET, SO_TIMESTAMPNS, &one, sizeof(one)) == 0) {
            step = "PACKET_AUXDATA";
            if (setsockopt(g_cap, SOL_PACKET, PACKET_AUXDATA, &one, sizeof(one)) == 0) {
                memset(&addr, 0, sizeof(addr));
                addr.sll_family = AF_PACKET;
                addr.sll_protocol = htons(ETH_P_ALL);
                addr.sll_ifindex = g_ifindex;
                step = "bind";
                if (bind(g_cap, (struct sockaddr *) &addr, sizeof(addr)) == 0) {
                    capture_start("pre", realtime_us());
                    progress(
                        "capture on %s: all frames, receive buffer %d bytes", g_ifname, granted);
                    return;
                }
            }
        }
    }
    progress("capture unavailable (%s: %s); the checks run without it", step, strerror(errno));
    if (g_cap >= 0)
        close(g_cap);
    g_cap = -1;
}

/* Drain the capture for the window that ends now and list its foreign frames,
 * then a summary. straggler_ms first lets frames the driver already counted
 * reach the socket. The capture moves on to the window named next. Never
 * blocks: every receive is non-blocking and the loop is bounded. */
static void capture_window(const char *next, unsigned straggler_ms)
{
    static uint8_t buf[CAPTURE_SNAP];
    unsigned own_out = 0, own_in = 0, stale = 0, foreign = 0, listed = 0, netdown = 0;
    unsigned other_if = 0, frames = 0;
    int recv_errno = 0;
    int64_t end_us;

    if (g_cap < 0) {
        capture_start(next, realtime_us());
        return;
    }
    if (straggler_ms)
        sleep_ms(straggler_ms);
    end_us = realtime_us();
    for (; frames < CAPTURE_MAX_FRAMES; frames++) {
        struct sockaddr_ll from;
        struct iovec iov = {buf, sizeof(buf)};
        union {
            struct cmsghdr align;
            char bytes[CMSG_SPACE(sizeof(struct timespec)) +
                       CMSG_SPACE(sizeof(struct tpacket_auxdata))];
        } control;
        struct msghdr msg;
        memset(&msg, 0, sizeof(msg));
        memset(&from, 0, sizeof(from));
        msg.msg_name = &from;
        msg.msg_namelen = sizeof(from);
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control.bytes;
        msg.msg_controllen = sizeof(control.bytes);
        ssize_t n = recvmsg(g_cap, &msg, MSG_TRUNC | MSG_DONTWAIT);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            if (errno == ENETDOWN) { /* pending from a down; frames may follow */
                netdown++;
                if (netdown > 64)
                    break;
                continue;
            }
            if (errno != EAGAIN && errno != EWOULDBLOCK)
                recv_errno = errno;
            break;
        }
        if (from.sll_ifindex != g_ifindex) {
            other_if++;
            continue;
        }
        size_t len = (size_t) n;
        size_t cap = len < sizeof(buf) ? len : sizeof(buf);
        int out = from.sll_pkttype == PACKET_OUTGOING;
        uint32_t seq;
        enum frame_class c = classify(buf, cap, len, out, &seq);
        if (c == FRAME_OWN) {
            if (out)
                own_out++;
            else
                own_in++;
            continue;
        }
        if (c == FRAME_STALE)
            stale++;
        foreign++;
        if (listed >= CAPTURE_LINES)
            continue;
        listed++;
        long long t_ms = -1;
        int vlan = -1;
        for (struct cmsghdr *m = CMSG_FIRSTHDR(&msg); m; m = CMSG_NXTHDR(&msg, m)) {
            if (m->cmsg_level == SOL_SOCKET && m->cmsg_type == SCM_TIMESTAMPNS) {
                struct timespec ts;
                memcpy(&ts, CMSG_DATA(m), sizeof(ts));
                t_ms = ((int64_t) ts.tv_sec * 1000000 + ts.tv_nsec / 1000 - g_t0_us) / 1000;
            }
            if (m->cmsg_level == SOL_PACKET && m->cmsg_type == PACKET_AUXDATA) {
                struct tpacket_auxdata aux;
                memcpy(&aux, CMSG_DATA(m), sizeof(aux));
                if (aux.tp_status & TP_STATUS_VLAN_VALID)
                    vlan = aux.tp_vlan_tci & 0xfff;
            }
        }
        const char *dir =
            out ? "out"
            : (from.sll_pkttype == PACKET_HOST || from.sll_pkttype == PACKET_BROADCAST ||
               from.sll_pkttype == PACKET_MULTICAST || from.sll_pkttype == PACKET_OTHERHOST)
                ? "in"
                : "other";
        char line1[FOREIGN_LINE], line2[FOREIGN_LINE];
        format_foreign(
            line1, line2, sizeof(line1), g_window, listed, dir, c, seq, buf, cap, len, vlan, t_ms);
        progress("%s", line1);
        progress("%s", line2);
    }
    if (foreign > listed)
        progress("foreign frame %s: %u more not listed", g_window, foreign - listed);

    /* Reading the statistics resets them: each window counts its own drops. */
    struct tpacket_stats st;
    socklen_t size = sizeof(st);
    char drops[16] = "?";
    if (getsockopt(g_cap, SOL_PACKET, PACKET_STATISTICS, &st, &size) == 0)
        snprintf(drops, sizeof(drops), "%u", st.tp_drops);
    char extra[96] = "";
    size_t used = 0;
    if (frames >= CAPTURE_MAX_FRAMES)
        used += (size_t) snprintf(extra + used, sizeof(extra) - used, ", drain cut at %u", frames);
    if (other_if)
        used += (size_t) snprintf(extra + used, sizeof(extra) - used, ", %u elsewhere", other_if);
    if (recv_errno)
        snprintf(extra + used, sizeof(extra) - used, ", recv: %s", strerror(recv_errno));
    progress("capture %s t=%lld..%lld: own out %u in %u, stale %u, foreign %u, enetdown %u, "
             "drops %s%s",
             g_window,
             (long long) ((g_window_start_us - g_t0_us) / 1000),
             (long long) ((end_us - g_t0_us) / 1000),
             own_out,
             own_in,
             stale,
             foreign,
             netdown,
             drops,
             extra);
    capture_start(next, end_us);
}

static void close_capture(void)
{
    if (g_cap >= 0)
        close(g_cap);
    g_cap = -1;
}

/* ---- frames ---- */

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
    capture_note_sent(seq, len);
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

/* Jumbo lengths: every length from the bare header to 160 bytes, then
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

/* Include both sides of the default and maximum RX copybreak thresholds. */
static uint32_t normal_length(unsigned i)
{
    static const uint32_t lengths[] = {60, 255, 256, 257, 1023, 1024, 1025, 1514};

    return lengths[i % (sizeof(lengths) / sizeof(lengths[0]))];
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
static int burst(unsigned count, const char *what, uint32_t (*frame_length)(unsigned))
{
    uint32_t first = g_seq;
    uint64_t deadline = now_ms() + STEP_MS;
    for (unsigned i = 0; i < count; i++) {
        if (now_ms() >= deadline)
            return fail("%s: %u of %u frames sent in %d ms", what, i, count, STEP_MS);
        if (send_frame(g_seq++, frame_length(i), what) != 0)
            return -1;
    }
    for (unsigned i = 0; i < count; i++)
        if (receive_frame(first + i, frame_length(i), deadline, what) != 0)
            return -1;
    return check_socket_drops(what);
}

/* Wait for counters to cover the step: reaped TX completions may trail RX.
 * Then reject duplicates for QUIET_MS. */
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
 * direction, no error may appear, and no counter may restart. The reason is
 * kept short so the whole line reaches the console log. */
static int idle_moved(const struct net_stats *start, const struct net_stats *end)
{
    return end->tx_packets != start->tx_packets || end->rx_packets != start->rx_packets ||
           end->rx_errors != start->rx_errors || end->tx_errors != start->tx_errors;
}

static int check_idle(const char *what, const struct net_stats *start, const struct net_stats *end)
{
    if (idle_moved(start, end))
        return fail("statistics %s: tx %+lld rx %+lld rxerr %+lld txerr %+lld with nothing sent",
                    what,
                    (long long) (end->tx_packets - start->tx_packets),
                    (long long) (end->rx_packets - start->rx_packets),
                    (long long) (end->rx_errors - start->rx_errors),
                    (long long) (end->tx_errors - start->tx_errors));
    return 0;
}

/* End a window the test judges as idle: list its foreign frames first. */
static void
capture_idle(const char *next, const struct net_stats *start, const struct net_stats *end)
{
    capture_window(next, idle_moved(start, end) ? CAPTURE_STRAGGLER_MS : 0);
}

static int run(void)
{
    struct net_stats start, normal0, normal1, a0, a1, d0, d1, e1, b0, b1;
    uint64_t carrier_ms = 0;
    uint64_t off_carrier_ms = UINT64_MAX;
    char off_carrier[48];
    unsigned window_a = LENGTH_FRAMES + BURST_FRAMES;

    /* ---- Step 1: the driver's interface, down ---- */
    g_ctl = socket(AF_PACKET, SOCK_DGRAM, 0);
    if (g_ctl < 0)
        return fail("control socket: %s", strerror(errno));
    if (find_interface() != 0)
        return -1;
    open_capture();
    if (find_loopback_bit() != 0 || open_sysfs() != 0 || set_up(0) != 0)
        return -1;
    if (g_expire_nfs_cache)
        sleep_ms(65000);
    if (read_stats(&start) != 0)
        return -1;
    capture_window("idle-normal", 0);
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

    /* ---- Step 2: normal MTU with queued short and full-size frames ---- */
    if (set_mtu(NORMAL_MTU) != 0 || set_loopback(1) != 0 || set_up(1) != 0 ||
        wait_carrier(&carrier_ms) != 0 || open_socket() != 0 || read_stats(&normal0) != 0)
        return -1;
    capture_idle("normal", &start, &normal0);
    if (check_idle("before normal MTU traffic", &start, &normal0) != 0 ||
        burst(NORMAL_FRAMES, "normal MTU", normal_length) != 0 ||
        settle(&normal0, NORMAL_FRAMES, &normal1, "normal MTU") != 0)
        return -1;
    capture_window("idle-jumbo", 0);
    if (check_window("normal MTU", &normal0, &normal1, NORMAL_FRAMES) != 0)
        return -1;
    progress("mtu %d: %d queued frames at 60, 255, 256, 257, 1023, 1024, 1025 and 1514 "
             "bytes verified, no socket drops",
             NORMAL_MTU,
             NORMAL_FRAMES);
    if (set_up(0) != 0)
        return -1;
    close_socket();

    /* ---- Step 3: jumbo MTU and loopback while down, then up ---- */
    if (set_mtu(TEST_MTU) != 0 || set_loopback(1) != 0 || set_up(1) != 0 ||
        wait_carrier(&carrier_ms) != 0 || open_socket() != 0)
        return -1;
    progress("mtu %d, loopback on, up: carrier after %llu ms",
             TEST_MTU,
             (unsigned long long) carrier_ms);

    /* ---- Step 4: lengths, one frame at a time ---- */
    if (read_stats(&a0) != 0)
        return -1;
    capture_idle("jumbo", &normal1, &a0);
    if (check_idle("before jumbo traffic", &normal1, &a0) != 0 || lengths_step() != 0)
        return -1;
    progress("lengths %d..%d, 1514, 4096, %d: %d frames verified",
             HDR_BYTES,
             SHORT_LAST,
             MAX_FRAME,
             LENGTH_FRAMES);

    /* ---- Step 5: queued traffic at jumbo MTU ---- */
    if (burst(BURST_FRAMES, "burst", burst_length) != 0 || settle(&a0, window_a, &a1, "burst") != 0)
        return -1;
    capture_window("drain", 0);
    progress("burst of %d sent before receiving: in order, no socket drops", BURST_FRAMES);

    /* ---- Step 6: down during a burst; loopback off; loopback on again ---- */
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
    capture_window("lb-off", 0);
    close_socket();
    /* The loopback-off interval ends at the down after it: e1 starts the
     * statistics again, so what a link partner sent meanwhile counts nowhere. */
    if (set_loopback(0) != 0 || set_up(1) != 0 || loopback_off_interval(&off_carrier_ms) != 0 ||
        set_up(0) != 0 || read_stats(&e1) != 0)
        return -1;
    capture_window("idle-final", 0);
    if (set_loopback(1) != 0 || set_up(1) != 0 || wait_carrier(&carrier_ms) != 0 ||
        open_socket() != 0 || read_stats(&b0) != 0)
        return -1;
    capture_idle("final", &e1, &b0);
    if (check_idle("between loopback on and the last burst", &e1, &b0) != 0)
        return -1;
    if (burst(FINAL_FRAMES, "after the drain", burst_length) != 0 ||
        settle(&b0, FINAL_FRAMES, &b1, "after the drain") != 0)
        return -1;
    capture_window("end", 0);
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

    /* ---- Step 7: the driver's statistics, loopback-off interval excluded ---- */
    if (check_window("steps 4-5", &a0, &a1, window_a) != 0 ||
        check_window("step 6", &b0, &b1, FINAL_FRAMES) != 0)
        return -1;
    uint64_t rx_errors = (d1.rx_errors - start.rx_errors) + (b1.rx_errors - e1.rx_errors);
    uint64_t tx_errors = (d1.tx_errors - start.tx_errors) + (b1.tx_errors - e1.tx_errors);
    if (rx_errors != 0 || tx_errors != 0)
        return fail("statistics: rx_errors %+lld tx_errors %+lld with loopback on",
                    (long long) rx_errors,
                    (long long) tx_errors);
    progress("statistics: tx_packets %+lld rx_packets %+lld for %d verified frames; "
             "rx_errors and tx_errors unchanged with loopback on",
             (long long) ((normal1.tx_packets - normal0.tx_packets) +
                          (a1.tx_packets - a0.tx_packets) + (b1.tx_packets - b0.tx_packets)),
             (long long) ((normal1.rx_packets - normal0.rx_packets) +
                          (a1.rx_packets - a0.rx_packets) + (b1.rx_packets - b0.rx_packets)),
             NORMAL_FRAMES + LENGTH_FRAMES + BURST_FRAMES + FINAL_FRAMES);

    /* ---- Step 8: leave the interface down with loopback off ---- */
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

/* ---- the decoder's self-test (--selftest): synthetic frames, no interface ---- */

static size_t put_eth(uint8_t *f, const uint8_t *dst, const uint8_t *src, unsigned type)
{
    memcpy(f, dst, 6);
    memcpy(f + 6, src, 6);
    f[12] = (uint8_t) (type >> 8);
    f[13] = (uint8_t) type;
    return HDR_BYTES;
}

static size_t
put_ipv4(uint8_t *p, unsigned proto, unsigned total, const uint8_t *src, const uint8_t *dst)
{
    memset(p, 0, 20);
    p[0] = 0x45;
    p[2] = (uint8_t) (total >> 8);
    p[3] = (uint8_t) total;
    p[6] = 0x40; /* don't fragment */
    p[8] = 64;
    p[9] = (uint8_t) proto;
    memcpy(p + 12, src, 4);
    memcpy(p + 16, dst, 4);
    return 20;
}

#define SELFTEST_LINE_MAX 150 /* printed characters, prefix included */

/* Classify frame f as the capture would and check the class and, when want
 * is given, the decoded second line; print both lines as they would appear. */
static int selftest_case(const char *name,
                         const uint8_t *f,
                         size_t len,
                         int out,
                         enum frame_class want_class,
                         const char *want)
{
    char line1[FOREIGN_LINE], line2[FOREIGN_LINE];
    size_t cap = len < CAPTURE_SNAP ? len : CAPTURE_SNAP;
    uint32_t seq;
    enum frame_class c = classify(f, cap, len, out, &seq);
    if (c != want_class) {
        printf("FROST_NET_SELFTEST_FAIL %s: class %d, expected %d\n", name, c, want_class);
        return 1;
    }
    if (c == FRAME_OWN) {
        printf("FROST_NET_SELFTEST %s: own seq=%u\n", name, seq);
        return 0;
    }
    format_foreign(line1,
                   line2,
                   sizeof(line1),
                   "idle-jumbo",
                   1,
                   out ? "out" : "in",
                   c,
                   seq,
                   f,
                   cap,
                   len,
                   -1,
                   70123);
    if (want && strcmp(line2, want) != 0) {
        printf("FROST_NET_SELFTEST_FAIL %s:\n  got  %s\n  want %s\n", name, line2, want);
        return 1;
    }
    size_t prefix = strlen("FROST_NET_LOOPBACK: ");
    size_t longest = strlen(line1) > strlen(line2) ? strlen(line1) : strlen(line2);
    if (prefix + longest > SELFTEST_LINE_MAX || strstr(line1, "FAIL") || strstr(line2, "FAIL") ||
        strstr(line1, "PASS") || strstr(line2, "PASS") || strstr(line2, "BUG") ||
        strstr(line2, "Oops")) {
        printf("FROST_NET_SELFTEST_FAIL %s: %zu characters or a console marker\n",
               name,
               prefix + longest);
        return 1;
    }
    printf("FROST_NET_SELFTEST %s (%zu characters):\n  %s\n  %s\n",
           name,
           prefix + longest,
           line1,
           line2);
    return 0;
}

static int selftest(void)
{
    static const uint8_t bcast[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
    static const uint8_t server[6] = {0x52, 0x54, 0x00, 0xab, 0xcd, 0xef};
    static const uint8_t board_ip[4] = {192, 168, 77, 2};
    static const uint8_t server_ip[4] = {192, 168, 77, 1};
    static const uint8_t mac[6] = {0x02, 0x11, 0x22, 0x33, 0x44, 0x55};
    static uint8_t f[MAX_FRAME];
    int bad = 0;
    size_t n;

    memcpy(g_mac, mac, sizeof(g_mac));
    g_run = 0x2d150dfdu | 0x01010101u;
    /* A window whose own frames are 1000..1009; 1003 and 1004 are short. */
    g_seq = 1000;
    capture_start("idle-jumbo", 0);
    capture_note_sent(1003, 20);
    capture_note_sent(1004, 14);
    g_seq = 1010;

    /* An ARP request from the board for the server. */
    memset(f, 0, sizeof(f));
    n = put_eth(f, bcast, g_mac, 0x0806);
    static const uint8_t arp_head[8] = {0, 1, 8, 0, 6, 4, 0, 1};
    memcpy(f + n, arp_head, 8);
    memcpy(f + n + 8, g_mac, 6);
    memcpy(f + n + 14, board_ip, 4);
    memcpy(f + n + 24, server_ip, 4);
    bad |=
        selftest_case("arp-request",
                      f,
                      n + 28,
                      1,
                      FRAME_FOREIGN,
                      "foreign frame idle-jumbo #1 arp request spa=192.168.77.2 tpa=192.168.77.1");
    /* The same request with an 802.1Q tag in the frame. */
    memmove(f + 16, f + 12, 30);
    f[12] = 0x81, f[13] = 0x00, f[14] = 0x00, f[15] = 0x05;
    bad |= selftest_case("vlan-arp",
                         f,
                         n + 32,
                         0,
                         FRAME_FOREIGN,
                         "foreign frame idle-jumbo #1 tag vlan=5 arp request spa=192.168.77.2 "
                         "tpa=192.168.77.1");
    /* A truncated ARP falls back to hex. */
    memset(f, 0, sizeof(f));
    n = put_eth(f, bcast, g_mac, 0x0806);
    memcpy(f + n, arp_head, 8);
    bad |= selftest_case("short-arp",
                         f,
                         n + 8,
                         0,
                         FRAME_FOREIGN,
                         "foreign frame idle-jumbo #1 data=0001080006040001");

    /* A TCP segment to the NFS server: options (32-byte header), 100 bytes. */
    memset(f, 0, sizeof(f));
    n = put_eth(f, server, g_mac, 0x0800);
    n += put_ipv4(f + n, 6, 20 + 32 + 100, board_ip, server_ip);
    uint8_t *t = f + n;
    t[0] = 837 >> 8;
    t[1] = 837 & 0xff;
    t[2] = 2049 >> 8;
    t[3] = 2049 & 0xff;
    t[4] = 0x12, t[5] = 0x34, t[6] = 0x56, t[7] = 0x78;
    t[8] = 0xde, t[9] = 0xad, t[10] = 0xbe, t[11] = 0xef;
    t[12] = 8 << 4;
    t[13] = 0x18; /* PSH, ACK */
    bad |= selftest_case("tcp-psh-ack",
                         f,
                         n + 32 + 100,
                         1,
                         FRAME_FOREIGN,
                         "foreign frame idle-jumbo #1 tcp 192.168.77.2:837>192.168.77.1:2049 PA "
                         "seq=305419896 ack=3735928559 pl=100");
    t[13] = 0x11; /* FIN, ACK */
    bad |= selftest_case("tcp-fin-ack",
                         f,
                         n + 32 + 100,
                         0,
                         FRAME_FOREIGN,
                         "foreign frame idle-jumbo #1 tcp 192.168.77.2:837>192.168.77.1:2049 FA "
                         "seq=305419896 ack=3735928559 pl=100");
    /* The longest TCP line: long addresses, ports and numbers, every flag. */
    memcpy(f + HDR_BYTES + 12, (const uint8_t[4]){192, 168, 177, 222}, 4);
    memcpy(f + HDR_BYTES + 16, (const uint8_t[4]){192, 168, 177, 111}, 4);
    memset(t, 0xff, 12);
    t[12] = 5 << 4;
    t[13] = 0xff;
    bad |= selftest_case("tcp-longest", f, n + 20, 1, FRAME_FOREIGN, NULL);

    /* A UDP datagram and an IGMP report (another IPv4 protocol). */
    memset(f, 0, sizeof(f));
    n = put_eth(f, bcast, g_mac, 0x0800);
    n += put_ipv4(f + n, 17, 20 + 8 + 300, board_ip, (const uint8_t[4]){255, 255, 255, 255});
    f[n] = 0, f[n + 1] = 68, f[n + 2] = 0, f[n + 3] = 67, f[n + 4] = (308 >> 8),
    f[n + 5] = 308 & 0xff;
    bad |=
        selftest_case("udp",
                      f,
                      n + 308,
                      1,
                      FRAME_FOREIGN,
                      "foreign frame idle-jumbo #1 udp 192.168.77.2:68>255.255.255.255:67 pl=300");
    memset(f, 0, sizeof(f));
    n = put_eth(f, (const uint8_t[6]){0x01, 0x00, 0x5e, 0x00, 0x00, 0x16}, g_mac, 0x0800);
    n += put_ipv4(f + n, 2, 20 + 16, board_ip, (const uint8_t[4]){224, 0, 0, 22});
    bad |= selftest_case("igmp",
                         f,
                         n + 16,
                         1,
                         FRAME_FOREIGN,
                         "foreign frame idle-jumbo #1 ipv4 proto=2 192.168.77.2>224.0.0.22 len=36");

    /* The window's own frames, each way; a second copy the same way is a
     * duplicate. Short frames match at their length out, padded in. */
    build_frame(f, 1001, 1514);
    bad |= selftest_case("own-1514-out", f, 1514, 1, FRAME_OWN, NULL);
    bad |= selftest_case("own-1514-in", f, 1514, 0, FRAME_OWN, NULL);
    bad |= selftest_case("duplicate-1514-in",
                         f,
                         1514,
                         0,
                         FRAME_DUPLICATE,
                         "foreign frame idle-jumbo #1 duplicate test frame seq=1001");
    build_frame(f, 1002, 40);
    bad |= selftest_case("own-40-out", f, 40, 1, FRAME_OWN, NULL);
    memset(f + 40, 0, MIN_FRAME - 40);
    bad |= selftest_case("own-40-padded-in", f, MIN_FRAME, 0, FRAME_OWN, NULL);
    build_frame(f, 1003, 20);
    bad |= selftest_case("own-20-out", f, 20, 1, FRAME_OWN, NULL);
    memset(f + 20, 0, MIN_FRAME - 20);
    bad |= selftest_case("own-20-padded-in", f, MIN_FRAME, 0, FRAME_OWN, NULL);
    build_frame(f, 1004, 14);
    memset(f + 14, 0xa5, MIN_FRAME - 14); /* padding is not checked */
    bad |= selftest_case("own-14-padded-in", f, MIN_FRAME, 0, FRAME_OWN, NULL);

    /* The lengths step as the board runs it: 14 to 23 bytes in turn, each
     * received padded before the next is sent. Every padded copy also
     * matches the 14-byte frame; none may count as its duplicate. */
    g_seq = 2000;
    capture_start("jumbo", 0);
    for (uint32_t slen = HDR_BYTES; slen < HDR_BYTES + TAG_BYTES; slen++) {
        uint32_t seq = g_seq++;
        capture_note_sent(seq, slen);
        build_frame(f, seq, slen);
        bad |= selftest_case("lengths-short-out", f, slen, 1, FRAME_OWN, NULL);
        memset(f + slen, slen & 1 ? 0 : 0x5a, MIN_FRAME - slen);
        bad |= selftest_case("lengths-short-padded-in", f, MIN_FRAME, 0, FRAME_OWN, NULL);
    }
    /* A second padded copy of the 20-byte frame is a duplicate. */
    build_frame(f, 2006, 20);
    memset(f + 20, 0, MIN_FRAME - 20);
    bad |= selftest_case("lengths-short-duplicate",
                         f,
                         MIN_FRAME,
                         0,
                         FRAME_DUPLICATE,
                         "foreign frame idle-jumbo #1 duplicate test frame seq=2006");
    g_seq = 1010;
    capture_start("idle-jumbo", 0);
    g_window_seq = 1000;

    /* A test frame of an earlier window, of this run: listed with its number. */
    build_frame(f, 998, 1514);
    bad |= selftest_case(
        "stale-test-frame",
        f,
        1514,
        0,
        FRAME_STALE,
        "foreign frame idle-jumbo #1 stale test frame seq=998 (this window from 1000)");
    build_frame(f, 998, 60);
    bad |= selftest_case("stale-test-frame-60", f, 60, 0, FRAME_STALE, NULL);
    build_frame(f, 1010, 60);
    bad |=
        selftest_case("ahead-test-frame",
                      f,
                      60,
                      0,
                      FRAME_AHEAD,
                      "foreign frame idle-jumbo #1 test frame seq=1010 not sent yet (next 1010)");
    /* A short frame of an earlier window has no whole tag. (In a window that
     * sent a 14-byte frame, which carries no tag, it would pass for that one:
     * only the lengths step sends one, and no idle window does.) */
    g_nshorts = 0;
    build_frame(f, 997, 20);
    memset(f + 20, 0, MIN_FRAME - 20);
    bad |= selftest_case("stale-short-frame",
                         f,
                         MIN_FRAME,
                         0,
                         FRAME_PARTIAL,
                         "foreign frame idle-jumbo #1 test frame without a whole tag "
                         "data=e5030000fd0d000000000000000000000000000000000000");
    /* Another run's frame (an earlier repetition, say). */
    build_frame(f, 1001, 60);
    f[18] ^= 0x10;
    bad |= selftest_case("other-run",
                         f,
                         60,
                         0,
                         FRAME_OTHER_RUN,
                         "foreign frame idle-jumbo #1 test frame of run 2d150ded seq=1001");
    /* The test ethertype from another address is foreign. */
    build_frame(f, 1001, 60);
    f[6] ^= 0x02;
    bad |= selftest_case("other-source", f, 60, 0, FRAME_FOREIGN, NULL);

    printf(bad ? "FROST_NET_SELFTEST_FAIL\n" : "FROST_NET_SELFTEST_PASS\n");
    return bad ? 1 : 0;
}

int main(int argc, char **argv)
{
    struct timespec ts;
    const char *expire_cache = getenv("FROST_NETTEST_EXPIRE_NFS_CACHE");
    g_expire_nfs_cache = expire_cache && strcmp(expire_cache, "1") == 0;
    const char *repetition = getenv("FROST_NETTEST_REPETITION");
    const char *verdict = "FROST_NET_LOOPBACK";
    char rep_tag[32] = "";
    unsigned rep = 0, reps = 0;
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc > 1 && strcmp(argv[1], "--selftest") == 0)
        return selftest();
    if (argc > 1 && argv[1][0] != '\0')
        g_requested_ifname = argv[1];
    /* "r/n": repetition r of n in one boot. Every repetition but the last
     * prints its verdict under FROST_NET_DIAG, which ends no capture. */
    if (repetition && sscanf(repetition, "%u/%u", &rep, &reps) == 2 && rep >= 1 && rep <= reps) {
        progress("repetition %u of %u", rep, reps);
        if (rep < reps) {
            verdict = "FROST_NET_DIAG";
            snprintf(rep_tag, sizeof(rep_tag), " rep=%u", rep);
        }
    }
    g_t0_us = realtime_us();
    clock_gettime(CLOCK_MONOTONIC, &ts);
    /* Every byte nonzero, so zero padding never reads as this run's tag. */
    g_run =
        ((uint32_t) ts.tv_nsec ^ (uint32_t) ts.tv_sec ^ ((uint32_t) getpid() << 12)) | 0x01010101u;
    /* Sequence numbers start from the run identifier, so an earlier run's
     * short frames are unlikely to repeat this run's; the top bit stays clear
     * so a run never wraps. */
    g_seq = (g_run * 2654435761u) & 0x7fffffffu;

    if (run() == 0) {
        close_capture();
        printf("%s_PASS%s\n", verdict, rep_tag);
        fflush(stdout);
        return 0;
    }
    char reason[sizeof(g_reason)];
    memcpy(reason, g_reason, sizeof(reason));
    /* The window the failure ended, before the restore takes the link down. */
    capture_window("restore", CAPTURE_STRAGGLER_MS);
    close_capture();
    int restored = restore();
    if (restored > 0)
        progress("%s down, loopback off", g_ifname);
    if (restored < 0)
        printf("%s_FAIL%s %s (restoring the interface: %s)\n", verdict, rep_tag, reason, g_reason);
    else
        printf("%s_FAIL%s %s\n", verdict, rep_tag, reason);
    fflush(stdout);
    return 1;
}
