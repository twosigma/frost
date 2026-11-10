// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
/*
 * FROST net10g 10GBASE-R Ethernet driver
 *
 * Copyright 2026 Two Sigma Open Source, LLC
 *
 * The network interface of the FROST RISC-V SoC: a soft 10GBASE-R MAC/PCS,
 * an RX and a TX descriptor ring in system memory on the SoC's coherent DMA
 * port, and one level interrupt. The register map and the descriptor,
 * interrupt and RESET contract this driver follows are documented in the
 * FROST repository, hw/rtl/peripherals/nic/README.md.
 *
 * Legacy registers use readl()/writel() at 4-aligned offsets. The extended
 * ring bases use one aligned readq()/writeq() each; split 32-bit stores are
 * deliberately refused by the NIC so a high/low pair cannot tear.
 *
 * The loopback feature is the NIC's MAC loopback (its raw transmit stream
 * into its own receiver) on a build whose two MAC directions share one clock,
 * and the transceiver's near-end PMA loopback otherwise. Open applies it
 * through RESET, so it changes only while the interface is down.
 *
 * A MAC direction whose clock domain restarts outside RESET (its clock was
 * lost, or the transceiver reset) drops READY, and the NIC disables that
 * direction with no interrupt of its own; a frame still being passed to or
 * from the MAC completes with ABORT. The poll re-enables the direction at the
 * LINK event for the carrier's return (frost_reenable()).
 *
 * The transmit queue lock serializes xmit and TX cleanup. Open and stop touch
 * the rings with NAPI disabled; reconfiguration synchronizes TX again after
 * the last poll, which may have woken the queue while the interface stays up.
 *
 * The source is built as a module for Debian's kernel (6.12 on Debian 13),
 * through DKMS on a Debian root and the same way for the kernel FROST packs, so
 * it uses only long-standing interfaces rather than the newest spelling of one.
 */

#include <linux/bitfield.h>
#include <linux/dma-mapping.h>
#include <linux/etherdevice.h>
#include <linux/ethtool.h>
#include <linux/if_vlan.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/netdevice.h>
#include <linux/of_net.h>
#include <linux/platform_device.h>
#include <linux/skbuff.h>
#include <linux/spinlock.h>
#include <linux/tcp.h>
#include <linux/timer.h>
#include <linux/u64_stats_sync.h>
#include <linux/unaligned.h>
#include <net/checksum.h>
#include <net/ip6_checksum.h>
#include <net/devlink.h>
#include <net/netdev_queues.h>
#include <net/page_pool/helpers.h>

/* Registers, 32 bits each */
#define NET10G_ID			0x000
#define NET10G_CTRL			0x004
#define NET10G_STATUS			0x008
#define NET10G_MAC_LO			0x00c
#define NET10G_MAC_HI			0x010
#define NET10G_RX_FIFO_LIMIT		0x014
#define NET10G_RX_FIFO_DEPTH		0x018
#define NET10G_PAUSE_CTRL		0x01c
#define NET10G_RX_BASE			0x020
#define NET10G_RX_SIZE			0x024
#define NET10G_RX_TAIL			0x028
#define NET10G_TX_BASE			0x030
#define NET10G_TX_SIZE			0x034
#define NET10G_TX_TAIL			0x038
#define NET10G_IRQ_STATUS		0x040
#define NET10G_IRQ_MASK			0x044
#define NET10G_IRQ_MASK_SET		0x054
#define NET10G_IRQ_MASK_CLR		0x058
#define NET10G_LINK			0x060
#define NET10G_PHY_CTRL			0x064
#define NET10G_PHY_STATUS		0x068
#define NET10G_RX_COALESCE		0x048
#define NET10G_TX_COALESCE		0x04c
#define NET10G_RX_ITR			NET10G_RX_COALESCE
#define NET10G_TX_ITR			NET10G_TX_COALESCE
#define NET10G_ABI_CTRL			0x06c
#define NET10G_RX_BASE64		0x070
#define NET10G_TX_BASE64		0x078

#define NET10G_ID_VALUE			0x4e494301

#define NET10G_CTRL_RX_EN		BIT(0)
#define NET10G_CTRL_TX_EN		BIT(1)
#define NET10G_CTRL_PROMISC		BIT(2)
#define NET10G_CTRL_RESET		BIT(8)

#define NET10G_STATUS_RESET_BUSY	BIT(2)
#define NET10G_STATUS_RX_READY		BIT(4)
#define NET10G_STATUS_TX_READY		BIT(5)

#define NET10G_IRQ_RX			BIT(0)
#define NET10G_IRQ_TX			BIT(1)
#define NET10G_IRQ_LINK			BIT(3)
#define NET10G_IRQ_ALL			GENMASK(4, 0)

#define NET10G_LINK_CARRIER		BIT(8)
#define NET10G_PHY_CTRL_MAC_LOOPBACK	BIT(0)
#define NET10G_PHY_CTRL_PMA_LOOPBACK	BIT(2)
#define NET10G_PHY_STATUS_CLK_SHARED	BIT(0)
#define NET10G_ABI_EXTENDED		BIT(0)
#define NET10G_ABI_EXTENDED_SUPPORTED	BIT(1)
/*
 * Checksum offload. Bit 3 reads one when the hardware inserts the TX checksum named in the
 * first descriptor of a frame and can report the RX checksum; bit 2 turns the RX report on
 * (RESET clears it).
 */
#define NET10G_ABI_RX_CSUM		BIT(2)
#define NET10G_ABI_CSUM_SUPPORTED	BIT(3)
/* Bit 6 reads one when a segment may carry up to 65535 bytes and a rejected one aborts its frame */
#define NET10G_ABI_TX_LONG_SEGMENTS	BIT(6)
/* Bit 5 reads one when the hardware has 802.3x pause (PAUSE_CTRL) */
#define NET10G_ABI_PAUSE_SUPPORTED	BIT(5)
/* PAUSE_CTRL: honour received PAUSE frames (bit 0), send pause and release frames (bit 1) */
#define NET10G_PAUSE_RX			BIT(0)
#define NET10G_PAUSE_TX			BIT(1)
/* Bit 4 reads one when the hardware segments stream frames */
#define NET10G_ABI_SEGMENT_SUPPORTED	BIT(4)

/* Interrupt moderation, per direction: [15:0] delay in ticks (1 us by reset default), [23:16] max count */
#define NET10G_COALESCE_DELAY		GENMASK(15, 0)
#define NET10G_COALESCE_FRAMES		GENMASK(23, 16)
#define NET10G_ITR_DELAY		NET10G_COALESCE_DELAY
#define NET10G_ITR_FRAMES		NET10G_COALESCE_FRAMES

/* TX frame flags and completion status (their word shifts with ABI mode) */
#define NET10G_DESC_TX_FIRST		BIT(16)
#define NET10G_DESC_TX_LAST		BIT(17)
#define NET10G_DESC_TX_PARAM		BIT(18)
#define NET10G_DESC_TX_SOP		NET10G_DESC_TX_FIRST
#define NET10G_DESC_TX_EOP		NET10G_DESC_TX_LAST
#define NET10G_DESC_TX_CTX		NET10G_DESC_TX_PARAM
/*
 * Hardware frame segmentation: a parameter descriptor ahead of the frame names its segmentation.
 * Its length is 0 and its length word holds the L4 offset / 2, the transport header length / 4,
 * the IP version and whether a VLAN tag precedes the IP header; its word 0 holds the max segment
 * size and the payload length.
 */
#define NET10G_PARAM_L4OFF		GENMASK(25, 19)
#define NET10G_PARAM_TCPHL		GENMASK(29, 26)
#define NET10G_PARAM_IP6		BIT(30)
#define NET10G_PARAM_VLAN		BIT(31)
#define NET10G_PARAM_MSS		GENMASK(13, 0)
#define NET10G_PARAM_PAYLOAD		GENMASK(31, 16)
#define NET10G_CTX_L4OFF		NET10G_PARAM_L4OFF
#define NET10G_CTX_TCPHL		NET10G_PARAM_TCPHL
#define NET10G_CTX_IP6			NET10G_PARAM_IP6
#define NET10G_CTX_VLAN			NET10G_PARAM_VLAN
#define NET10G_CTX_MSS			NET10G_PARAM_MSS
#define NET10G_CTX_PAYLOAD		NET10G_PARAM_PAYLOAD
/* The most header bytes the segmentation stage holds */
#define NET10G_SEGMENT_MAX_HDR		160
#define NET10G_TSO_MAX_HDR		NET10G_SEGMENT_MAX_HDR
/* TX checksum request, in the first descriptor's length word: start / 2 and offset / 2 */
#define NET10G_DESC_TX_CSUM_START	GENMASK(24, 18)
#define NET10G_DESC_TX_CSUM_OFFSET	GENMASK(31, 25)
#define NET10G_DESC_LEN			GENMASK(15, 0)
#define NET10G_DESC_DONE		BIT(16)
#define NET10G_DESC_CMPL		NET10G_DESC_DONE
#define NET10G_DESC_DD			NET10G_DESC_DONE
#define NET10G_DESC_TRUNC		BIT(17)
#define NET10G_DESC_ERR			BIT(18)
#define NET10G_DESC_ABORT		BIT(19)
/* RX: the checksum of the frame after the Ethernet header is valid (word 3 [15:0] in the
 * legacy layout, word 2 [31:16] in the extended layout).
 */
#define NET10G_DESC_CSUM_VALID		BIT(20)

/*
 * Each ring holds a power-of-two number of entries, so at most one fewer is posted (TAIL == HEAD is
 * empty). ethtool -G sets them from FROST_RING_MIN to FROST_RING_MAX (the NIC takes 4 to 65536).
 * The default RX depth absorbs bursts that arrive while the CPU is busy elsewhere; at 128 the NIC
 * dropped frames under load.
 */
#define FROST_RING_DEFAULT		512
#define FROST_RING_MIN			64
#define FROST_RING_MAX			4096
#define FROST_RING_BYTES(entries) \
	((entries) * sizeof(struct frost_desc))
#define FROST_RING_ALIGN_MASK		31	/* BASE is 32-byte aligned */

/*
 * RX ingress FIFO: 8-byte words. RX_FIFO_DEPTH reads the built depth (0 on hardware without the
 * limit register); RX_FIFO_LIMIT, which RESET returns to FROST_FIFO_LIMIT_DEFAULT, is the
 * occupancy at which the FIFO reports full to the MAC.
 */
#define FROST_FIFO_WORD_BYTES		8
#define FROST_FIFO_LIMIT_MIN		8
#define FROST_FIFO_LIMIT_DEFAULT	512

#define FROST_MAX_MTU			9000
#define FROST_POLL_US			1000
#define FROST_RESET_TIMEOUT_US		USEC_PER_SEC
#define FROST_ENABLE_TRIES		3
#define FROST_REFILL_MS			100

/*
 * Default interrupt moderation, per direction: notify after the delay in microseconds or the
 * frame count, whichever comes first. Measured on the VCU118 at MTU 1500, these raised bulk TX
 * and request/response rates over notifying on every completion; longer delays cut
 * request/response rates by a quarter.
 */
#define FROST_RX_COALESCE_US		20
#define FROST_RX_COALESCE_FRAMES	8
#define FROST_TX_COALESCE_US		50
#define FROST_TX_COALESCE_FRAMES	16
#define FROST_RX_ITR_US			FROST_RX_COALESCE_US
#define FROST_RX_ITR_FRAMES		FROST_RX_COALESCE_FRAMES
#define FROST_TX_ITR_US			FROST_TX_COALESCE_US
#define FROST_TX_ITR_FRAMES		FROST_TX_COALESCE_FRAMES

/*
 * RX buffers come from a page pool and are recycled: the NIC writes a frame FROST_RX_HEADROOM
 * bytes into a page, and the poll builds the skb around it. NET_IP_ALIGN keeps the IP header
 * aligned, as __netdev_alloc_skb_ip_align() did.
 */
#define FROST_RX_HEADROOM		(NET_SKB_PAD + NET_IP_ALIGN)

/*
 * Older NICs accept at most 9216 bytes in one TX descriptor (nic_pkg::MaxFrameBytes, checked per
 * descriptor in nic_tx_engine), so a longer segment goes out as several descriptors over the same
 * mapping; with ABI_CTRL bit 6 a segment may carry 65535 bytes (priv->tx_desc_max). A segmented skb (at
 * most GSO_LEGACY_MAX_SIZE) takes its parameter descriptor, its head and fragments, and up to
 * GSO_LEGACY_MAX_SIZE / FROST_TX_DESC_MAX extra pieces on older NICs; the queue stop and wake
 * thresholds below assume that worst case.
 */
#define FROST_TX_DESC_MAX		9216
#define FROST_TX_STOP_DESCS		(MAX_SKB_FRAGS + 3 + \
					 DIV_ROUND_UP(GSO_LEGACY_MAX_SIZE, FROST_TX_DESC_MAX))
#define FROST_TX_WAKE_DESCS		(2 * FROST_TX_STOP_DESCS)

/* One ring descriptor: 16 bytes, two per 32-byte line */
struct frost_desc {
	__le32 word0;		/* address low */
	__le32 word1;		/* legacy length or extended address high */
	__le32 word2;		/* legacy status or extended length */
	__le32 word3;		/* legacy reserved or extended status */
};

struct frost_buf {
	struct sk_buff *skb;	/* TX */
	struct page *page;	/* RX */
	dma_addr_t dma;
	unsigned int len;	/* the mapped length */
	bool page_mapping;	/* TX: pair skb_frag_dma_map with dma_unmap_page */
};

struct frost_priv {
	struct net_device *ndev;
	struct device *dev;	/* every DMA allocation, map and unmap */
	void __iomem *base;
	int irq;

	struct napi_struct napi;
	struct timer_list refill_timer;

	/* Protects running and promisc; held for every non-RESET CTRL write */
	spinlock_t ctrl_lock;
	bool running;
	bool promisc;

	bool link_refresh;	/* the next poll reads LINK */
	bool broken;		/* a RESET did not complete; never cleared */
	bool wide_abi;		/* selected only when hardware and DMA API support it */
	bool csum_abi;		/* hardware checksum offload present */
	bool sg_abi;		/* descriptor chaining, advertised by the long-segment ABI */
	bool segment_abi;	/* hardware frame segmentation present */
	u32 rx_coalesce, tx_coalesce;	/* interrupt moderation, written at each open */
	unsigned long reenables;	/* CTRL rewrites after a READY loss */

	u32 rx_entries, tx_entries;	/* ring sizes, applied at the next open */
	u32 rx_mask, tx_mask;		/* entries - 1 */
	u32 rx_fifo_depth;	/* built RX FIFO depth in words; 0 without RX_FIFO_LIMIT */
	u32 rx_fifo_limit;	/* RX FIFO limit in words, written at each open */
	u32 pause;		/* NET10G_PAUSE_* bits, written at each open */
	bool pause_abi;		/* hardware 802.3x pause present */
	u32 tx_desc_max;	/* the longest TX segment one descriptor may carry */
	struct devlink *devlink;
	bool hw_up;		/* the rings are published: frost_up() completed */

	unsigned int rx_buf_len;
	unsigned int rx_truesize;	/* the page-pool allocation each RX buffer occupies */
	struct page_pool *rx_pool;
	struct frost_desc *rx_ring;
	dma_addr_t rx_ring_dma;
	struct frost_buf *rx_bufs;
	u32 rx_clean;		/* oldest posted descriptor */
	u32 rx_tail;		/* next descriptor to post */

	struct frost_desc *tx_ring;
	dma_addr_t tx_ring_dma;
	struct frost_buf *tx_bufs;
	u32 tx_clean;		/* oldest posted descriptor */
	u32 tx_head;		/* next descriptor to post */
	bool tx_frame_err;	/* a segment of the frame being reaped failed */

	struct u64_stats_sync rx_syncp;
	u64_stats_t rx_packets;
	u64_stats_t rx_bytes;
	u64_stats_t rx_errors;

	struct u64_stats_sync tx_syncp;
	u64_stats_t tx_packets;
	u64_stats_t tx_bytes;
	u64_stats_t tx_errors;
	u64_stats_t tx_dropped;
};

static void frost_desc_post(const struct frost_priv *priv,
			    struct frost_desc *desc, dma_addr_t dma, u32 len)
{
	desc->word0 = cpu_to_le32(lower_32_bits(dma));
	if (priv->wide_abi) {
		desc->word1 = cpu_to_le32(upper_32_bits(dma));
		desc->word2 = cpu_to_le32(len);
		desc->word3 = 0;
	} else {
		desc->word1 = cpu_to_le32(len);
		desc->word2 = 0;
		desc->word3 = 0;
	}
}

static void frost_param_post(const struct frost_priv *priv, struct frost_desc *desc,
			     u32 word0, u32 flags)
{
	desc->word0 = cpu_to_le32(word0);
	if (priv->wide_abi) {
		desc->word1 = 0;
		desc->word2 = cpu_to_le32(flags);
	} else {
		desc->word1 = cpu_to_le32(flags);
		desc->word2 = 0;
	}
	desc->word3 = 0;
}
#define frost_ctx_post frost_param_post

static u32 frost_desc_status(const struct frost_priv *priv,
			     const struct frost_desc *desc)
{
	const __le32 *status = priv->wide_abi ? &desc->word3 : &desc->word2;

	return le32_to_cpu(READ_ONCE(*status));
}

static u32 frost_tx_free(const struct frost_priv *priv)
{
	return priv->tx_mask -
	       ((priv->tx_head - priv->tx_clean) & priv->tx_mask);
}

/*
 * Every CTRL write other than RESET carries both enables and the intended
 * PROMISC: an enable bit written as 0 disables that direction, and every such
 * write reloads PROMISC. Called with ctrl_lock held.
 */
static u32 frost_ctrl_value(const struct frost_priv *priv)
{
	return NET10G_CTRL_RX_EN | NET10G_CTRL_TX_EN |
	       (priv->promisc ? NET10G_CTRL_PROMISC : 0);
}

/*
 * Request a poll outside the interrupt handler. Flush the mask write before
 * scheduling so the device stays masked from the request through the poll.
 */
static void frost_schedule(struct frost_priv *priv)
{
	writel(NET10G_IRQ_ALL, priv->base + NET10G_IRQ_MASK_CLR);
	readl(priv->base + NET10G_IRQ_MASK);
	napi_schedule(&priv->napi);
}

static irqreturn_t frost_irq(int irq, void *data)
{
	struct frost_priv *priv = data;

	/*
	 * Masked until the poll completes. The read flushes the mask store to
	 * the device before the handler returns, so the interrupt controller's
	 * completion sees the line low.
	 */
	writel(NET10G_IRQ_ALL, priv->base + NET10G_IRQ_MASK_CLR);
	readl(priv->base + NET10G_IRQ_MASK);
	napi_schedule(&priv->napi);
	return IRQ_HANDLED;
}

static void frost_refill_timer(struct timer_list *t)
{
	struct frost_priv *priv = container_of(t, struct frost_priv,
					       refill_timer);

	frost_schedule(priv);
}

/*
 * Fill RX to rx_mask outstanding buffers; stop on allocation failure
 * and return the number posted. Write only rx_tail, never a descriptor the
 * NIC may hold. The page pool maps each page once, when it first allocates
 * it, and keeps the mapping while the page is recycled.
 * The NIC uses reads accepted after TAIL covers the descriptor; dma_wmb()
 * orders its four words before the doorbell so those reads see the new data.
 */
static unsigned int frost_rx_fill(struct frost_priv *priv, gfp_t gfp)
{
	unsigned int posted = 0;

	while (((priv->rx_tail + 1) & priv->rx_mask) != priv->rx_clean) {
		struct frost_desc *desc = &priv->rx_ring[priv->rx_tail];
		struct frost_buf *buf = &priv->rx_bufs[priv->rx_tail];
		struct page *page;
		dma_addr_t dma;

		page = page_pool_alloc_pages(priv->rx_pool, gfp | __GFP_NOWARN);
		if (!page)
			break;
		dma = page_pool_get_dma_addr(page) + FROST_RX_HEADROOM;
		buf->page = page;
		buf->dma = dma;
		buf->len = priv->rx_buf_len;

		frost_desc_post(priv, desc, dma, priv->rx_buf_len);
		priv->rx_tail = (priv->rx_tail + 1) & priv->rx_mask;
		posted++;
	}

	if (posted) {
		dma_wmb();
		writel(priv->rx_tail, priv->base + NET10G_RX_TAIL);
	}
	return posted;
}

static void frost_tx_unmap(struct frost_priv *priv, struct frost_buf *buf)
{
	/* Parameter descriptors and nonfinal pieces do not own a mapping. */
	if (!buf->len)
		return;
	if (buf->page_mapping)
		dma_unmap_page(priv->dev, buf->dma, buf->len, DMA_TO_DEVICE);
	else
		dma_unmap_single(priv->dev, buf->dma, buf->len, DMA_TO_DEVICE);
	buf->len = 0;
}

static void frost_tx_reap(struct frost_priv *priv, int budget)
{
	struct net_device *ndev = priv->ndev;
	struct netdev_queue *txq = netdev_get_tx_queue(ndev, 0);
	unsigned int pkts = 0, bytes = 0;	/* every completed descriptor */
	unsigned int good = 0, good_bytes = 0, errors = 0;

	__netif_tx_lock(txq, smp_processor_id());
	while (priv->tx_clean != priv->tx_head) {
		struct frost_desc *desc = &priv->tx_ring[priv->tx_clean];
		struct frost_buf *buf = &priv->tx_bufs[priv->tx_clean];
		u32 status = frost_desc_status(priv, desc);

		/*
		 * The NIC writes DONE once every buffer read it issued has
		 * returned: the whole frame, or less with ERR or ABORT.
		 */
		if (!(status & NET10G_DESC_DONE))
			break;
		pkts++;
		bytes += buf->len;
		frost_tx_unmap(priv, buf);
		if (status & (NET10G_DESC_ERR | NET10G_DESC_ABORT))
			priv->tx_frame_err = true;
		/* Only a frame's last segment holds its skb: the frame is complete now. */
		if (buf->skb) {
			if (priv->tx_frame_err) {
				errors++;
			} else {
				good += skb_is_gso(buf->skb) ? skb_shinfo(buf->skb)->gso_segs : 1;
				good_bytes += buf->skb->len;
			}
			priv->tx_frame_err = false;
			napi_consume_skb(buf->skb, budget);
			buf->skb = NULL;
		}
		priv->tx_clean = (priv->tx_clean + 1) & priv->tx_mask;
	}

	if (pkts) {
		u64_stats_update_begin(&priv->tx_syncp);
		u64_stats_add(&priv->tx_packets, good);
		u64_stats_add(&priv->tx_bytes, good_bytes);
		u64_stats_add(&priv->tx_errors, errors);
		u64_stats_update_end(&priv->tx_syncp);
	}

	/*
	 * BQL gets the bytes of every completed descriptor, errors included,
	 * as xmit reported them. No wake once the core has cleared
	 * netif_running(): stop is about to free the ring.
	 */
	__netif_txq_completed_wake(txq, pkts, bytes, frost_tx_free(priv), 1,
				   !netif_running(ndev));
	__netif_tx_unlock(txq);
}

static int frost_rx_reap(struct frost_priv *priv, int budget)
{
	struct net_device *ndev = priv->ndev;
	unsigned int packets = 0, bytes = 0, errors = 0;
	int work = 0;

	while (work < budget && priv->rx_clean != priv->rx_tail) {
		struct frost_desc *desc = &priv->rx_ring[priv->rx_clean];
		struct frost_buf *buf = &priv->rx_bufs[priv->rx_clean];
		u32 status = frost_desc_status(priv, desc);
		u32 len = status & NET10G_DESC_LEN;
		struct page *page = buf->page;
		struct sk_buff *skb;

		if (!(status & NET10G_DESC_DD))
			break;
		/*
		 * DD and the length come from the one load above. The NIC
		 * writes the status only after every data write it issued for
		 * the frame has been answered; dma_rmb() orders the frame data
		 * loads (eth_type_trans() reads the header) after that load.
		 */
		dma_rmb();
		buf->page = NULL;
		priv->rx_clean = (priv->rx_clean + 1) & priv->rx_mask;
		work++;

		if ((status & (NET10G_DESC_TRUNC | NET10G_DESC_ERR |
			       NET10G_DESC_ABORT)) ||
		    len < ETH_HLEN || len > buf->len) {
			errors++;
			page_pool_recycle_direct(priv->rx_pool, page);
			continue;
		}
		dma_sync_single_for_cpu(priv->dev, buf->dma, len, DMA_FROM_DEVICE);
		/* The skb takes the page; freeing the skb returns the page to the pool */
		skb = napi_build_skb(page_address(page), priv->rx_truesize);
		if (unlikely(!skb)) {
			errors++;
			page_pool_recycle_direct(priv->rx_pool, page);
			continue;
		}
		skb_mark_for_recycle(skb);
		skb_reserve(skb, FROST_RX_HEADROOM);
		skb_put(skb, len);
		if ((ndev->features & NETIF_F_RXCSUM) &&
		    (status & NET10G_DESC_CSUM_VALID)) {
			/*
			 * The sum of the bytes after the Ethernet header, in the order they sit in
			 * memory: the kernel's folded sum for this little-endian CPU.
			 */
			u32 sum = priv->wide_abi ?
				  le32_to_cpu(READ_ONCE(desc->word2)) >> 16 :
				  le32_to_cpu(READ_ONCE(desc->word3)) & 0xffff;

			skb->csum = (__force __wsum)sum;
			skb->ip_summed = CHECKSUM_COMPLETE;
		}
		skb->protocol = eth_type_trans(skb, ndev);
		napi_gro_receive(&priv->napi, skb);
		packets++;
		bytes += len;
	}

	if (packets || errors) {
		u64_stats_update_begin(&priv->rx_syncp);
		u64_stats_add(&priv->rx_packets, packets);
		u64_stats_add(&priv->rx_bytes, bytes);
		u64_stats_add(&priv->rx_errors, errors);
		u64_stats_update_end(&priv->rx_syncp);
	}
	return work;
}

/*
 * Re-enable directions disabled by loss of MAC READY. Write both enables and
 * PROMISC; each direction accepts its enable when it is READY and its ring is
 * valid, and resumes at HEAD.
 * A direction still not READY rejects the write with CONFIG_ERR and masked
 * DESC_ERR; retry on the LINK event after READY returns. Only the poll calls
 * this, outside open/stop RESET, so RESET_BUSY cannot discard the write.
 */
static void frost_reenable(struct frost_priv *priv)
{
	u32 ctrl, status, lost = 0;

	spin_lock(&priv->ctrl_lock);
	if (priv->running) {
		ctrl = readl(priv->base + NET10G_CTRL);
		status = readl(priv->base + NET10G_STATUS);
		if (!(ctrl & NET10G_CTRL_RX_EN) &&
		    (status & NET10G_STATUS_RX_READY))
			lost |= NET10G_CTRL_RX_EN;
		if (!(ctrl & NET10G_CTRL_TX_EN) &&
		    (status & NET10G_STATUS_TX_READY))
			lost |= NET10G_CTRL_TX_EN;
		if (lost)
			writel(frost_ctrl_value(priv),
			       priv->base + NET10G_CTRL);
	}
	spin_unlock(&priv->ctrl_lock);

	if (!lost)
		return;
	priv->reenables++;
	if (net_ratelimit())
		netdev_info(priv->ndev,
			    "re-enabled%s%s after a MAC domain reset (%lu)\n",
			    (lost & NET10G_CTRL_RX_EN) ? " RX" : "",
			    (lost & NET10G_CTRL_TX_EN) ? " TX" : "",
			    priv->reenables);
}

static int frost_poll(struct napi_struct *napi, int budget)
{
	struct frost_priv *priv = container_of(napi, struct frost_priv, napi);
	struct net_device *ndev = priv->ndev;
	bool refresh;
	int work;
	u32 st;

	/*
	 * A zero budget (netpoll) reaps TX only. It acknowledges nothing: with
	 * no RX scan, an acknowledgment could erase the only notification of
	 * a completed RX descriptor.
	 */
	if (unlikely(!budget)) {
		frost_tx_reap(priv, 0);
		return 0;
	}

	/*
	 * Busy polling calls this without a scheduling request, possibly with
	 * the device unmasked. Mask and flush here as well, so every
	 * positive-budget poll runs masked until napi_complete_done() succeeds.
	 */
	writel(NET10G_IRQ_ALL, priv->base + NET10G_IRQ_MASK_CLR);
	readl(priv->base + NET10G_IRQ_MASK);

	/*
	 * Acknowledge before scanning: the scans find earlier completions,
	 * and later ones reassert the bit for unmasking. A late acknowledgment
	 * could erase a completion the scan missed. Writing 1 starts a new
	 * moderation interval; COALESCE defaults to 0, raising on the first completion.
	 * The read flushes the acknowledgment before descriptor loads.
	 */
	st = readl(priv->base + NET10G_IRQ_STATUS);
	writel(st | NET10G_IRQ_RX | NET10G_IRQ_TX,
	       priv->base + NET10G_IRQ_STATUS);
	readl(priv->base + NET10G_IRQ_STATUS);

	/*
	 * The poll updates carrier; probe and teardown also clear it. Read LINK
	 * after acknowledgment so later changes reassert the event. Carrier returns
	 * after MAC READY, making LINK the retry point for lost enables.
	 */
	refresh = xchg(&priv->link_refresh, false);
	if ((st & NET10G_IRQ_LINK) || refresh) {
		if (readl(priv->base + NET10G_LINK) & NET10G_LINK_CARRIER)
			netif_carrier_on(ndev);
		else
			netif_carrier_off(ndev);
		frost_reenable(priv);
	}

	frost_tx_reap(priv, budget);
	work = frost_rx_reap(priv, budget);

	/*
	 * With nothing posted no RX completion can request a poll, so a failed
	 * refill that leaves the ring empty retries from the timer. Meanwhile
	 * the NIC holds frames in its FIFO and drops whole frames beyond it.
	 */
	frost_rx_fill(priv, GFP_ATOMIC);
	if (priv->rx_clean == priv->rx_tail)
		mod_timer(&priv->refill_timer,
			  jiffies + msecs_to_jiffies(FROST_REFILL_MS));

	/* An exhausted budget keeps the device masked for the next poll */
	if (work < budget && napi_complete_done(napi, work))
		writel(NET10G_IRQ_RX | NET10G_IRQ_TX | NET10G_IRQ_LINK,
		       priv->base + NET10G_IRQ_MASK_SET);
	return work;
}

static void frost_free_rings(struct frost_priv *priv)
{
	if (priv->rx_ring)
		dma_free_coherent(priv->dev, FROST_RING_BYTES(priv->rx_entries), priv->rx_ring,
				  priv->rx_ring_dma);
	if (priv->tx_ring)
		dma_free_coherent(priv->dev, FROST_RING_BYTES(priv->tx_entries), priv->tx_ring,
				  priv->tx_ring_dma);
	kvfree(priv->rx_bufs);
	kvfree(priv->tx_bufs);
	/* Pages still held by skbs return to the pool later; destroy waits for them */
	if (priv->rx_pool)
		page_pool_destroy(priv->rx_pool);
	priv->rx_pool = NULL;
	priv->rx_ring = NULL;
	priv->tx_ring = NULL;
	priv->rx_bufs = NULL;
	priv->tx_bufs = NULL;
}

static int frost_alloc_rings(struct frost_priv *priv)
{
	/*
	 * One RX buffer per page-pool allocation: headroom, the frame, and the
	 * skb_shared_info that napi_build_skb() places at the end.
	 */
	unsigned int truesize = SKB_DATA_ALIGN(FROST_RX_HEADROOM + priv->rx_buf_len) +
				SKB_DATA_ALIGN(sizeof(struct skb_shared_info));
	struct page_pool_params pp = {
		.order = get_order(truesize),
		.flags = PP_FLAG_DMA_MAP | PP_FLAG_DMA_SYNC_DEV,
		.pool_size = priv->rx_entries,
		.nid = NUMA_NO_NODE,
		.dev = priv->dev,
		.napi = &priv->napi,
		.dma_dir = DMA_FROM_DEVICE,
		.offset = FROST_RX_HEADROOM,
		.max_len = priv->rx_buf_len,
	};

	priv->rx_truesize = PAGE_SIZE << pp.order;
	priv->rx_pool = page_pool_create(&pp);
	if (IS_ERR(priv->rx_pool)) {
		priv->rx_pool = NULL;
		return -ENOMEM;
	}

	/* dma_alloc_coherent() returns zeroed, page-aligned memory */
	priv->rx_ring = dma_alloc_coherent(priv->dev, FROST_RING_BYTES(priv->rx_entries),
					   &priv->rx_ring_dma, GFP_KERNEL);
	priv->tx_ring = dma_alloc_coherent(priv->dev, FROST_RING_BYTES(priv->tx_entries),
					   &priv->tx_ring_dma, GFP_KERNEL);
	priv->rx_bufs = kvcalloc(priv->rx_entries, sizeof(*priv->rx_bufs),
				 GFP_KERNEL);
	priv->tx_bufs = kvcalloc(priv->tx_entries, sizeof(*priv->tx_bufs),
				 GFP_KERNEL);
	if (!priv->rx_ring || !priv->tx_ring || !priv->rx_bufs ||
	    !priv->tx_bufs || (priv->rx_ring_dma & FROST_RING_ALIGN_MASK) ||
	    (priv->tx_ring_dma & FROST_RING_ALIGN_MASK)) {
		frost_free_rings(priv);
		return -ENOMEM;
	}
	return 0;
}

/*
 * Free published memory only after RESET_BUSY clears: all DMA responses have
 * returned and no new requests can issue. The caller must stop xmit, NAPI,
 * the refill timer, and interrupts; RESET_BUSY discards configuration writes.
 * On timeout, leak the rings and posted buffers, mark broken, and detach.
 */
static void frost_reset_and_free(struct frost_priv *priv)
{
	struct net_device *ndev = priv->ndev;
	unsigned int dropped = 0;
	u32 status;

	writel(NET10G_CTRL_RESET, priv->base + NET10G_CTRL);
	if (readl_poll_timeout(priv->base + NET10G_STATUS, status,
			       !(status & NET10G_STATUS_RESET_BUSY),
			       FROST_POLL_US, FROST_RESET_TIMEOUT_US)) {
		netdev_err(ndev, "RESET timed out (STATUS %#x), rings leaked\n",
			   status);
		/*
		 * The core ignores ndo_stop's return value, so a device whose
		 * RESET never completed is detached: later opens and ethtool
		 * requests fail visibly instead of the failure staying silent.
		 */
		priv->broken = true;
		/* Returned skbs must not refer to NAPI after this detached netdev is freed. */
		page_pool_disable_direct_recycling(priv->rx_pool);
		netif_device_detach(ndev);
		netif_carrier_off(ndev);
		return;
	}

	while (priv->rx_clean != priv->rx_tail) {
		struct frost_buf *buf = &priv->rx_bufs[priv->rx_clean];

		page_pool_put_full_page(priv->rx_pool, buf->page, false);
		buf->page = NULL;
		priv->rx_clean = (priv->rx_clean + 1) & priv->rx_mask;
	}

	while (priv->tx_clean != priv->tx_head) {
		struct frost_buf *buf = &priv->tx_bufs[priv->tx_clean];

		frost_tx_unmap(priv, buf);
		dropped += !!buf->skb;
		dev_kfree_skb(buf->skb);
		buf->skb = NULL;
		priv->tx_clean = (priv->tx_clean + 1) & priv->tx_mask;
	}
	if (dropped) {
		u64_stats_update_begin(&priv->tx_syncp);
		u64_stats_add(&priv->tx_dropped, dropped);
		u64_stats_update_end(&priv->tx_syncp);
	}

	netdev_tx_reset_queue(netdev_get_tx_queue(ndev, 0));
	frost_free_rings(priv);
	netif_carrier_off(ndev);
}

/*
 * Quiesce before frost_reset_and_free(), including failed opens after NAPI
 * was enabled. Busy polling needs no interrupt and can arm the refill timer
 * or unmask the device.
 */
static void frost_quiesce(struct frost_priv *priv)
{
	/* The poll is the only place the refill timer is armed */
	napi_disable(&priv->napi);
	timer_delete_sync(&priv->refill_timer);

	writel(NET10G_IRQ_ALL, priv->base + NET10G_IRQ_MASK_CLR);
	readl(priv->base + NET10G_IRQ_MASK);
	synchronize_irq(priv->irq);
	/* A last completion can wake TX during a running reconfiguration. */
	netif_tx_disable(priv->ndev);
}

/*
 * RESET returned RX_FIFO_LIMIT and PAUSE_CTRL to their defaults. A write is ignored while a previous one is still
 * crossing to the MAC clock, so repeat it until the read-back shows the value in effect.
 */
static int frost_apply_fifo_limit(struct frost_priv *priv)
{
	unsigned int tries;
	u32 val = 0;

	if (priv->pause_abi && priv->pause) {
		writel(priv->pause, priv->base + NET10G_PAUSE_CTRL);
		if (readl(priv->base + NET10G_PAUSE_CTRL) != priv->pause) {
			netdev_err(priv->ndev, "pause control not accepted\n");
			return -EIO;
		}
	}
	if (!priv->rx_fifo_depth || priv->rx_fifo_limit == FROST_FIFO_LIMIT_DEFAULT)
		return 0;
	for (tries = 0; tries < FROST_ENABLE_TRIES; tries++) {
		writel(priv->rx_fifo_limit, priv->base + NET10G_RX_FIFO_LIMIT);
		if (!readl_poll_timeout(priv->base + NET10G_RX_FIFO_LIMIT, val,
					val == priv->rx_fifo_limit, 1, FROST_POLL_US))
			return 0;
	}
	netdev_err(priv->ndev, "RX FIFO limit not accepted (read %u, wanted %u words)\n", val,
		   priv->rx_fifo_limit);
	return -EIO;
}

static int frost_up(struct net_device *ndev)
{
	struct frost_priv *priv = netdev_priv(ndev);
	const u32 ready = NET10G_STATUS_RX_READY | NET10G_STATUS_TX_READY;
	const u32 enables = NET10G_CTRL_RX_EN | NET10G_CTRL_TX_EN;
	u32 phy_ctrl = 0;
	unsigned int tries;
	u32 status;
	int err;

	if (priv->broken)
		return -EIO;

	priv->rx_mask = priv->rx_entries - 1;
	priv->tx_mask = priv->tx_entries - 1;
	priv->rx_clean = 0;
	priv->rx_tail = 0;
	priv->tx_clean = 0;
	priv->tx_head = 0;
	priv->tx_frame_err = false;
	priv->rx_buf_len = ndev->mtu + ETH_HLEN + VLAN_HLEN;

	err = frost_alloc_rings(priv);
	if (err)
		return err;

	/*
	 * Write PHY_CTRL before RESET. MAC loopback requires CLK_SHARED and
	 * is sampled during RX MAC reset. PMA loopback restarts the receiver;
	 * READY can fall after the wait below, so enable retries allow for it.
	 * RESET_BUSY discards configuration writes. Wait for it to clear,
	 * then wait separately for READY.
	 */
	if (ndev->features & NETIF_F_LOOPBACK) {
		if (readl(priv->base + NET10G_PHY_STATUS) &
		    NET10G_PHY_STATUS_CLK_SHARED)
			phy_ctrl = NET10G_PHY_CTRL_MAC_LOOPBACK;
		else
			phy_ctrl = NET10G_PHY_CTRL_PMA_LOOPBACK;
	}
	writel(phy_ctrl, priv->base + NET10G_PHY_CTRL);
	writel(NET10G_CTRL_RESET, priv->base + NET10G_CTRL);
	if (readl_poll_timeout(priv->base + NET10G_STATUS, status,
			       !(status & NET10G_STATUS_RESET_BUSY),
			       FROST_POLL_US, FROST_RESET_TIMEOUT_US)) {
		/*
		 * These rings have not been published, and any previous stop
		 * completed RESET, so they can be freed before detaching.
		 */
		netdev_err(ndev, "RESET did not complete (STATUS %#x)\n",
			   status);
		priv->broken = true;
		netif_device_detach(ndev);
		frost_free_rings(priv);
		return -EIO;
	}
	if (readl_poll_timeout(priv->base + NET10G_STATUS, status,
			       (status & ready) == ready,
			       FROST_POLL_US, FROST_RESET_TIMEOUT_US)) {
		netdev_err(ndev, "MAC not ready (STATUS %#x)\n", status);
		frost_free_rings(priv);
		return -EIO;
	}

	/* RESET returned the ring registers to their defaults */
	writel(get_unaligned_le32(ndev->dev_addr), priv->base + NET10G_MAC_LO);
	writel(get_unaligned_le16(ndev->dev_addr + 4),
	       priv->base + NET10G_MAC_HI);
	if (priv->csum_abi) {
		/* RESET returned the layout to legacy and the RX checksum report off */
		u32 abi = NET10G_ABI_RX_CSUM | (priv->wide_abi ? NET10G_ABI_EXTENDED : 0);

		writel(abi, priv->base + NET10G_ABI_CTRL);
		if ((readl(priv->base + NET10G_ABI_CTRL) & abi) != abi) {
			netdev_err(ndev, "checksum offload mode refused\n");
			err = -EIO;
			goto err_reset;
		}
	}
	if (priv->wide_abi) {
		if (!priv->csum_abi)
			writel(NET10G_ABI_EXTENDED, priv->base + NET10G_ABI_CTRL);
		if ((readl(priv->base + NET10G_ABI_CTRL) &
		     (NET10G_ABI_EXTENDED | NET10G_ABI_EXTENDED_SUPPORTED)) !=
		    (NET10G_ABI_EXTENDED | NET10G_ABI_EXTENDED_SUPPORTED)) {
			netdev_err(ndev, "extended address mode refused\n");
			err = -EIO;
			goto err_reset;
		}
		writeq(priv->rx_ring_dma, priv->base + NET10G_RX_BASE64);
		writeq(priv->tx_ring_dma, priv->base + NET10G_TX_BASE64);
	} else {
		writel(lower_32_bits(priv->rx_ring_dma),
		       priv->base + NET10G_RX_BASE);
		writel(lower_32_bits(priv->tx_ring_dma),
		       priv->base + NET10G_TX_BASE);
	}
	writel(ilog2(priv->rx_entries), priv->base + NET10G_RX_SIZE);
	writel(ilog2(priv->tx_entries), priv->base + NET10G_TX_SIZE);
	if ((priv->wide_abi ?
	     readq(priv->base + NET10G_RX_BASE64) != priv->rx_ring_dma ||
	     readq(priv->base + NET10G_TX_BASE64) != priv->tx_ring_dma :
	     readl(priv->base + NET10G_RX_BASE) !=
	     lower_32_bits(priv->rx_ring_dma) ||
	     readl(priv->base + NET10G_TX_BASE) !=
	     lower_32_bits(priv->tx_ring_dma)) ||
	    readl(priv->base + NET10G_RX_SIZE) != ilog2(priv->rx_entries) ||
	    readl(priv->base + NET10G_TX_SIZE) != ilog2(priv->tx_entries)) {
		netdev_err(ndev, "ring registers not accepted\n");
		err = -EIO;
		goto err_reset;
	}

	err = frost_apply_fifo_limit(priv);
	if (err)
		goto err_reset;

	/* An empty RX ring would never produce the poll that refills it */
	if (!frost_rx_fill(priv, GFP_KERNEL)) {
		err = -ENOMEM;
		goto err_reset;
	}

	writel(priv->rx_coalesce, priv->base + NET10G_RX_COALESCE);
	writel(priv->tx_coalesce, priv->base + NET10G_TX_COALESCE);
	writel(NET10G_IRQ_ALL, priv->base + NET10G_IRQ_STATUS);
	napi_enable(&priv->napi);

	spin_lock_bh(&priv->ctrl_lock);
	priv->promisc = !!(ndev->flags & IFF_PROMISC);
	priv->running = true;
	writel(frost_ctrl_value(priv), priv->base + NET10G_CTRL);
	spin_unlock_bh(&priv->ctrl_lock);

	/*
	 * Enables require READY and valid rings. Ring registers were checked,
	 * but PMA loopback can drop READY after the wait; retry a bounded
	 * number of times.
	 */
	for (tries = 1; (readl(priv->base + NET10G_CTRL) & enables) != enables;
	     tries++) {
		if (tries == FROST_ENABLE_TRIES ||
		    readl_poll_timeout(priv->base + NET10G_STATUS, status,
				       (status & ready) == ready,
				       FROST_POLL_US, FROST_RESET_TIMEOUT_US)) {
			netdev_err(ndev, "enable refused (STATUS %#x)\n",
				   readl(priv->base + NET10G_STATUS));
			spin_lock_bh(&priv->ctrl_lock);
			priv->running = false;
			spin_unlock_bh(&priv->ctrl_lock);
			frost_quiesce(priv);
			err = -EIO;
			goto err_reset;
		}
		spin_lock_bh(&priv->ctrl_lock);
		writel(frost_ctrl_value(priv), priv->base + NET10G_CTRL);
		spin_unlock_bh(&priv->ctrl_lock);
	}

	netif_start_queue(ndev);
	priv->hw_up = true;

	/*
	 * The device is still masked (RESET cleared IRQ_MASK). The first poll
	 * reads LINK, publishes the carrier and unmasks.
	 */
	priv->link_refresh = true;
	local_bh_disable();
	frost_schedule(priv);
	local_bh_enable();
	return 0;

err_reset:
	frost_reset_and_free(priv);
	return err;
}

static int frost_down(struct net_device *ndev)
{
	struct frost_priv *priv = netdev_priv(ndev);

	/* A failed ring resize leaves the interface up with no rings published */
	if (!priv->hw_up)
		return 0;

	/*
	 * The core has cleared netif_running() and deactivated the qdisc:
	 * xmit is over and completions no longer wake the queue. A ring resize
	 * calls this on a running interface; netif_tx_disable() waits for any
	 * transmit in progress and stops the queue.
	 */
	netif_tx_disable(ndev);
	spin_lock_bh(&priv->ctrl_lock);
	priv->running = false;
	spin_unlock_bh(&priv->ctrl_lock);

	frost_quiesce(priv);
	frost_reset_and_free(priv);
	priv->hw_up = false;
	return 0;
}

static netdev_tx_t frost_start_xmit(struct sk_buff *skb,
				    struct net_device *ndev)
{
	struct frost_priv *priv = netdev_priv(ndev);
	struct netdev_queue *txq = netdev_get_tx_queue(ndev, 0);
	const skb_frag_t *frag;
	struct frost_desc *desc;
	struct frost_buf *buf;
	dma_addr_t dma[MAX_SKB_FRAGS + 1];
	u32 seg_len[MAX_SKB_FRAGS + 1];
	unsigned int nseg, ndesc, nmapped = 0, i;
	u32 csum_req = 0, ctx0 = 0, ctx1 = 0;
	bool head_mapped, is_gso = skb_is_gso(skb);

	/*
	 * Frame segmentation: the NIC cuts the frame at the MSS and adds each segment's TCP length to the
	 * checksum field, which therefore starts as the pseudo-header sum without the length.
	 * frost_features_check() has already sent unsuitable skbs to software GSO.
	 */
	if (is_gso) {
		unsigned int l4 = skb_transport_offset(skb), tcphl = tcp_hdrlen(skb);
		bool ip6 = vlan_get_protocol(skb) == htons(ETH_P_IPV6);

		if (unlikely(skb_cow_head(skb, 0))) {
			dev_kfree_skb_any(skb);
			u64_stats_update_begin(&priv->tx_syncp);
			u64_stats_inc(&priv->tx_dropped);
			u64_stats_update_end(&priv->tx_syncp);
			return NETDEV_TX_OK;
		}
		if (ip6)
			tcp_hdr(skb)->check = ~csum_ipv6_magic(&ipv6_hdr(skb)->saddr,
							       &ipv6_hdr(skb)->daddr, 0,
							       IPPROTO_TCP, 0);
		else
			tcp_hdr(skb)->check = ~csum_tcpudp_magic(ip_hdr(skb)->saddr,
								 ip_hdr(skb)->daddr, 0,
								 IPPROTO_TCP, 0);
		ctx0 = FIELD_PREP(NET10G_PARAM_MSS, skb_shinfo(skb)->gso_size) |
		       FIELD_PREP(NET10G_PARAM_PAYLOAD, skb->len - l4 - tcphl);
		ctx1 = NET10G_DESC_TX_PARAM | FIELD_PREP(NET10G_PARAM_L4OFF, l4 / 2) |
		       FIELD_PREP(NET10G_PARAM_TCPHL, tcphl / 4) |
		       (ip6 ? NET10G_PARAM_IP6 : 0) |
		       (skb_network_offset(skb) == ETH_HLEN + VLAN_HLEN ? NET10G_PARAM_VLAN : 0);
	}

	/*
	 * CHECKSUM_PARTIAL: the NIC sums from csum_start to the end of the frame and stores the
	 * result at csum_start + csum_offset, as the kernel defines it (the field holds the
	 * pseudo-header sum and is part of the sum). The request holds both in 16-bit units, so an
	 * odd or far offset takes the software path.
	 */
	if (!is_gso && skb->ip_summed == CHECKSUM_PARTIAL) {
		unsigned int start = skb_checksum_start_offset(skb);
		unsigned int offset = skb->csum_offset;

		if (priv->csum_abi && !(start & 1) && !(offset & 1) && offset &&
		    start / 2 <= FIELD_MAX(NET10G_DESC_TX_CSUM_START) &&
		    offset / 2 <= FIELD_MAX(NET10G_DESC_TX_CSUM_OFFSET)) {
			csum_req = FIELD_PREP(NET10G_DESC_TX_CSUM_START, start / 2) |
				   FIELD_PREP(NET10G_DESC_TX_CSUM_OFFSET, offset / 2);
		} else if (skb_checksum_help(skb)) {
			dev_kfree_skb_any(skb);
			u64_stats_update_begin(&priv->tx_syncp);
			u64_stats_inc(&priv->tx_dropped);
			u64_stats_update_end(&priv->tx_syncp);
			return NETDEV_TX_OK;
		}
	}

	/*
	 * One descriptor per tx_desc_max bytes of each non-empty segment: the linear head,
	 * then each fragment.
	 */
	head_mapped = skb_headlen(skb) != 0;
	nseg = head_mapped;
	ndesc = DIV_ROUND_UP(skb_headlen(skb), priv->tx_desc_max);
	for (i = 0; i < skb_shinfo(skb)->nr_frags; i++) {
		unsigned int size = skb_frag_size(&skb_shinfo(skb)->frags[i]);

		nseg += size != 0;
		ndesc += DIV_ROUND_UP(size, priv->tx_desc_max);
	}

	/* The queue stops with FROST_TX_STOP_DESCS free, so this should not happen */
	if (unlikely(!nseg || frost_tx_free(priv) < ndesc + is_gso)) {
		if (nseg) {
			netif_stop_subqueue(ndev, 0);
			return NETDEV_TX_BUSY;
		}
		dev_kfree_skb_any(skb);
		u64_stats_update_begin(&priv->tx_syncp);
		u64_stats_inc(&priv->tx_dropped);
		u64_stats_update_end(&priv->tx_syncp);
		return NETDEV_TX_OK;
	}

	/* Map every segment before posting any, so a failed mapping unwinds cleanly. */
	if (head_mapped) {
		dma[0] = dma_map_single(priv->dev, skb->data, skb_headlen(skb),
					DMA_TO_DEVICE);
		if (unlikely(dma_mapping_error(priv->dev, dma[0])))
			goto map_fail;
		seg_len[0] = skb_headlen(skb);
		nmapped = 1;
	}
	for (i = 0; i < skb_shinfo(skb)->nr_frags; i++) {
		frag = &skb_shinfo(skb)->frags[i];
		if (!skb_frag_size(frag))
			continue;
		dma[nmapped] = skb_frag_dma_map(priv->dev, frag, 0, skb_frag_size(frag),
						DMA_TO_DEVICE);
		if (unlikely(dma_mapping_error(priv->dev, dma[nmapped])))
			goto map_fail;
		seg_len[nmapped++] = skb_frag_size(frag);
	}

	/*
	 * No padding: the MAC pads short frames to 60 bytes. The first segment
	 * carries FIRST, the last LAST and the skb. The stores precede dma_wmb()
	 * and the doorbell, as for RX.
	 */
	if (is_gso) {
		desc = &priv->tx_ring[priv->tx_head];
		buf = &priv->tx_bufs[priv->tx_head];
		frost_param_post(priv, desc, ctx0, ctx1);
		buf->skb = NULL;
		buf->dma = 0;
		buf->len = 0;
		priv->tx_head = (priv->tx_head + 1) & priv->tx_mask;
	}
	/*
	 * A segment longer than tx_desc_max goes out in pieces over its one mapping. Only the
	 * mapping's last piece records the mapping (dma, full length) for the unmap and BQL; the
	 * others have length 0 there, as a parameter descriptor does.
	 */
	for (i = 0; i < nmapped; i++) {
		u32 off;

		for (off = 0; off < seg_len[i]; off += priv->tx_desc_max) {
			u32 piece = min_t(u32, seg_len[i] - off, priv->tx_desc_max);
			bool first = i == 0 && off == 0;
			bool last_piece = off + piece == seg_len[i];
			bool last = i == nmapped - 1 && last_piece;
			unsigned int flags = (first ? NET10G_DESC_TX_FIRST | csum_req : 0) |
					     (last ? NET10G_DESC_TX_LAST : 0);

			desc = &priv->tx_ring[priv->tx_head];
			buf = &priv->tx_bufs[priv->tx_head];
			frost_desc_post(priv, desc, dma[i] + off, piece | flags);
			buf->skb = last ? skb : NULL;
			buf->dma = last_piece ? dma[i] : 0;
			buf->len = last_piece ? seg_len[i] : 0;
			buf->page_mapping = !(head_mapped && i == 0);

			netdev_tx_sent_queue(txq, buf->len);
			priv->tx_head = (priv->tx_head + 1) & priv->tx_mask;
		}
	}
	dma_wmb();
	writel(priv->tx_head, priv->base + NET10G_TX_TAIL);

	netif_subqueue_maybe_stop(ndev, 0, frost_tx_free(priv), FROST_TX_STOP_DESCS,
				  FROST_TX_WAKE_DESCS);
	return NETDEV_TX_OK;

map_fail:
	for (i = 0; i < nmapped; i++) {
		if (head_mapped && i == 0)
			dma_unmap_single(priv->dev, dma[0], seg_len[0], DMA_TO_DEVICE);
		else
			dma_unmap_page(priv->dev, dma[i], seg_len[i], DMA_TO_DEVICE);
	}
	dev_kfree_skb_any(skb);
	u64_stats_update_begin(&priv->tx_syncp);
	u64_stats_inc(&priv->tx_dropped);
	u64_stats_update_end(&priv->tx_syncp);
	return NETDEV_TX_OK;
}

static void frost_set_rx_mode(struct net_device *ndev)
{
	struct frost_priv *priv = netdev_priv(ndev);

	/* The filter always accepts group addresses: ALLMULTI needs nothing */
	spin_lock_bh(&priv->ctrl_lock);
	priv->promisc = !!(ndev->flags & IFF_PROMISC);
	if (priv->running)
		writel(frost_ctrl_value(priv), priv->base + NET10G_CTRL);
	spin_unlock_bh(&priv->ctrl_lock);
}

static int frost_set_features(struct net_device *ndev,
			      netdev_features_t features)
{
	/*
	 * Change loopback only while down. The next open applies the recorded
	 * feature through PHY_CTRL and RESET.
	 */
	if (((ndev->features ^ features) & NETIF_F_LOOPBACK) &&
	    netif_running(ndev))
		return -EBUSY;
	return 0;
}

static int frost_change_mtu(struct net_device *ndev, int new_mtu)
{
	/* RX buffers are sized from the MTU at open */
	if (netif_running(ndev))
		return -EBUSY;
	WRITE_ONCE(ndev->mtu, new_mtu);
	return 0;
}

static void frost_get_stats64(struct net_device *ndev,
			      struct rtnl_link_stats64 *stats)
{
	struct frost_priv *priv = netdev_priv(ndev);
	unsigned int start;

	do {
		start = u64_stats_fetch_begin(&priv->rx_syncp);
		stats->rx_packets = u64_stats_read(&priv->rx_packets);
		stats->rx_bytes = u64_stats_read(&priv->rx_bytes);
		stats->rx_errors = u64_stats_read(&priv->rx_errors);
	} while (u64_stats_fetch_retry(&priv->rx_syncp, start));

	do {
		start = u64_stats_fetch_begin(&priv->tx_syncp);
		stats->tx_packets = u64_stats_read(&priv->tx_packets);
		stats->tx_bytes = u64_stats_read(&priv->tx_bytes);
		stats->tx_errors = u64_stats_read(&priv->tx_errors);
		stats->tx_dropped = u64_stats_read(&priv->tx_dropped);
	} while (u64_stats_fetch_retry(&priv->tx_syncp, start));
}

/*
 * The segmentation stage takes TCP over IPv4 or IPv6 behind an Ethernet header with at most one
 * VLAN tag, headers up to NET10G_TSO_MAX_HDR bytes and an even L4 offset. Anything else is
 * segmented by the stack before it reaches the driver. IPv6 extension headers also take the
 * software path: a routing header can change the pseudo-header's final destination.
 */
static netdev_features_t frost_features_check(struct sk_buff *skb, struct net_device *ndev,
					      netdev_features_t features)
{
	if (skb_is_gso(skb)) {
		unsigned int l3 = skb_network_offset(skb);
		unsigned int hdr = skb_tcp_all_headers(skb);

		if ((skb_shinfo(skb)->gso_type & ~(SKB_GSO_TCPV4 | SKB_GSO_TCPV6)) ||
		    skb->encapsulation || (l3 != ETH_HLEN && l3 != ETH_HLEN + VLAN_HLEN) ||
		    (vlan_get_protocol(skb) == htons(ETH_P_IPV6) &&
		     skb_transport_offset(skb) != l3 + sizeof(struct ipv6hdr)) ||
		    (skb_transport_offset(skb) & 1) || hdr > NET10G_TSO_MAX_HDR ||
		    skb_shinfo(skb)->gso_size > FIELD_MAX(NET10G_CTX_MSS) || skb->len <= hdr ||
		    skb->len - hdr > FIELD_MAX(NET10G_CTX_PAYLOAD))
			features &= ~NETIF_F_GSO_MASK;
	}
	return features;
}

static const struct net_device_ops frost_netdev_ops = {
	.ndo_open		= frost_up,
	.ndo_stop		= frost_down,
	.ndo_start_xmit		= frost_start_xmit,
	.ndo_set_rx_mode	= frost_set_rx_mode,
	.ndo_set_mac_address	= eth_mac_addr,
	.ndo_validate_addr	= eth_validate_addr,
	.ndo_change_mtu		= frost_change_mtu,
	.ndo_set_features	= frost_set_features,
	.ndo_get_stats64	= frost_get_stats64,
	.ndo_features_check	= frost_features_check,
};

static void frost_get_drvinfo(struct net_device *ndev,
			      struct ethtool_drvinfo *info)
{
	struct frost_priv *priv = netdev_priv(ndev);

	strscpy(info->driver, KBUILD_MODNAME, sizeof(info->driver));
	strscpy(info->bus_info, dev_name(priv->dev), sizeof(info->bus_info));
}

/*
 * Interrupt moderation: ethtool's usecs and max frames set the hardware's per-direction delay
 * and completion count. A delay of 0 interrupts on the first completion, as at reset. The NIC
 * applies a new setting from its next interval; a running interface is updated at once.
 */
static int frost_get_coalesce(struct net_device *ndev, struct ethtool_coalesce *ec,
			      struct kernel_ethtool_coalesce *kernel_coal,
			      struct netlink_ext_ack *extack)
{
	struct frost_priv *priv = netdev_priv(ndev);

	ec->rx_coalesce_usecs = FIELD_GET(NET10G_COALESCE_DELAY, priv->rx_coalesce);
	ec->rx_max_coalesced_frames = FIELD_GET(NET10G_COALESCE_FRAMES, priv->rx_coalesce);
	ec->tx_coalesce_usecs = FIELD_GET(NET10G_COALESCE_DELAY, priv->tx_coalesce);
	ec->tx_max_coalesced_frames = FIELD_GET(NET10G_COALESCE_FRAMES, priv->tx_coalesce);
	return 0;
}

static int frost_set_coalesce(struct net_device *ndev, struct ethtool_coalesce *ec,
			      struct kernel_ethtool_coalesce *kernel_coal,
			      struct netlink_ext_ack *extack)
{
	struct frost_priv *priv = netdev_priv(ndev);

	if (ec->rx_coalesce_usecs > FIELD_MAX(NET10G_COALESCE_DELAY) ||
	    ec->tx_coalesce_usecs > FIELD_MAX(NET10G_COALESCE_DELAY) ||
	    ec->rx_max_coalesced_frames > FIELD_MAX(NET10G_COALESCE_FRAMES) ||
	    ec->tx_max_coalesced_frames > FIELD_MAX(NET10G_COALESCE_FRAMES))
		return -EINVAL;

	priv->rx_coalesce = FIELD_PREP(NET10G_COALESCE_DELAY, ec->rx_coalesce_usecs) |
			    FIELD_PREP(NET10G_COALESCE_FRAMES, ec->rx_max_coalesced_frames);
	priv->tx_coalesce = FIELD_PREP(NET10G_COALESCE_DELAY, ec->tx_coalesce_usecs) |
			    FIELD_PREP(NET10G_COALESCE_FRAMES, ec->tx_max_coalesced_frames);
	if (netif_running(ndev)) {
		writel(priv->rx_coalesce, priv->base + NET10G_RX_COALESCE);
		writel(priv->tx_coalesce, priv->base + NET10G_TX_COALESCE);
	}
	return 0;
}

/*
 * Ring sizes: powers of two from FROST_RING_MIN to FROST_RING_MAX, applied by closing and
 * reopening a running interface (the RX and TX rings, the page pool and the buffer arrays are
 * rebuilt). A size that is not a power of two is rounded up, and a size outside the range is
 * refused.
 */
static void frost_get_ringparam(struct net_device *ndev, struct ethtool_ringparam *ring,
				struct kernel_ethtool_ringparam *kernel_ring,
				struct netlink_ext_ack *extack)
{
	struct frost_priv *priv = netdev_priv(ndev);

	ring->rx_max_pending = FROST_RING_MAX;
	ring->tx_max_pending = FROST_RING_MAX;
	ring->rx_pending = priv->rx_entries;
	ring->tx_pending = priv->tx_entries;
}

/*
 * Apply new ring sizes and RX FIFO limit. A running interface is closed and reopened with them
 * (RESET clears the NIC's counters); a failed reopen restores the previous values. RTNL held.
 */
static int frost_reconfigure(struct net_device *ndev, u32 rx, u32 tx, u32 fifo, u32 pause)
{
	struct frost_priv *priv = netdev_priv(ndev);
	u32 old_rx = priv->rx_entries, old_tx = priv->tx_entries, old_fifo = priv->rx_fifo_limit;
	u32 old_pause = priv->pause;
	int err;

	ASSERT_RTNL();
	if (rx == old_rx && tx == old_tx && fifo == old_fifo && pause == old_pause)
		return 0;
	if (priv->broken)
		return -EIO;
	if (!netif_running(ndev)) {
		priv->rx_entries = rx;
		priv->tx_entries = tx;
		priv->rx_fifo_limit = fifo;
		priv->pause = pause;
		return 0;
	}

	/* The rings are freed at their old size, then rebuilt at the new one */
	frost_down(ndev);
	if (priv->broken)
		return -EIO;
	priv->rx_entries = rx;
	priv->tx_entries = tx;
	priv->rx_fifo_limit = fifo;
	priv->pause = pause;
	err = frost_up(ndev);
	if (!err)
		return 0;

	netdev_err(ndev, "reconfiguration failed (%d), restoring rx %u tx %u FIFO %u words\n",
		   err, old_rx, old_tx, old_fifo);
	priv->rx_entries = old_rx;
	priv->tx_entries = old_tx;
	priv->rx_fifo_limit = old_fifo;
	priv->pause = old_pause;
	if (frost_up(ndev))
		netdev_err(ndev, "restoring the previous settings failed; reopen the interface\n");
	return err;
}

static int frost_set_ringparam(struct net_device *ndev, struct ethtool_ringparam *ring,
			       struct kernel_ethtool_ringparam *kernel_ring,
			       struct netlink_ext_ack *extack)
{
	struct frost_priv *priv = netdev_priv(ndev);

	if (ring->rx_pending < FROST_RING_MIN || ring->tx_pending < FROST_RING_MIN ||
	    ring->rx_pending > FROST_RING_MAX || ring->tx_pending > FROST_RING_MAX) {
		NL_SET_ERR_MSG_FMT_MOD(extack, "ring sizes must be %u to %u",
				       FROST_RING_MIN, FROST_RING_MAX);
		return -EINVAL;
	}
	return frost_reconfigure(ndev, roundup_pow_of_two(ring->rx_pending),
				 roundup_pow_of_two(ring->tx_pending), priv->rx_fifo_limit,
				 priv->pause);
}

/* The NIC's 64-bit event counters (nic_pkg CntRxFrames ...), plain reads at 8-byte offsets */
#define NET10G_COUNTERS			0x080

static const char frost_stat_names[][ETH_GSTRING_LEN] = {
	"rx_frames",
	"rx_bytes",
	"rx_filtered",
	"rx_truncated",
	"rx_desc_err",
	"rx_aborted",
	"tx_frames",
	"tx_bytes",
	"tx_desc_err",
	"tx_aborted",
	"rx_mac_overflow",
	"rx_mac_bad_frame",
	"rx_mac_bad_fcs",
	"rx_pcs_bad_block",
	"tx_mac_drop",
	"tx_pcs_bad_block",
	"rx_gmii_preamble_drop",
	"rx_gmii_rx_er",
	"rx_pause_frames",
	"tx_pause_frames",
	"tx_paused_cycles",
};
#define FROST_NUM_STATS			ARRAY_SIZE(frost_stat_names)

static int frost_get_sset_count(struct net_device *ndev, int sset)
{
	if (sset != ETH_SS_STATS)
		return -EOPNOTSUPP;
	return FROST_NUM_STATS;
}

static void frost_get_strings(struct net_device *ndev, u32 stringset, u8 *data)
{
	if (stringset == ETH_SS_STATS)
		memcpy(data, frost_stat_names, sizeof(frost_stat_names));
}

/*
 * One aligned 64-bit read per counter in the extended ABI. The legacy ABI reads the two halves
 * with 32-bit accesses, so the high half is read again to catch a carry between them.
 */
static u64 frost_read_counter(const struct frost_priv *priv, unsigned int index)
{
	void __iomem *reg = priv->base + NET10G_COUNTERS + 8 * index;
	u32 hi, lo;

	if (priv->wide_abi)
		return readq(reg);
	do {
		hi = readl(reg + 4);
		lo = readl(reg);
	} while (hi != readl(reg + 4));
	return ((u64)hi << 32) | lo;
}

static void frost_get_ethtool_stats(struct net_device *ndev, struct ethtool_stats *stats,
				    u64 *data)
{
	struct frost_priv *priv = netdev_priv(ndev);
	unsigned int i;

	for (i = 0; i < FROST_NUM_STATS; i++)
		data[i] = frost_read_counter(priv, i);
}

/*
 * 802.3x pause: rx_pause honours PAUSE frames received (the transmitter stops for the pause time),
 * tx_pause sends pause when the RX FIFO fills and release when it drains. Pause autonegotiation is not
 * offered, so ethtool -A autoneg on is refused. Applied by reopening a running interface, as the
 * hardware accepts the bits only while RX is disabled.
 */
static void frost_get_pauseparam(struct net_device *ndev, struct ethtool_pauseparam *pause)
{
	struct frost_priv *priv = netdev_priv(ndev);

	pause->autoneg = 0;
	pause->rx_pause = !!(priv->pause & NET10G_PAUSE_RX);
	pause->tx_pause = !!(priv->pause & NET10G_PAUSE_TX);
}

static int frost_set_pauseparam(struct net_device *ndev, struct ethtool_pauseparam *pause)
{
	struct frost_priv *priv = netdev_priv(ndev);

	if (!priv->pause_abi)
		return -EOPNOTSUPP;
	if (pause->autoneg)
		return -EINVAL;
	return frost_reconfigure(ndev, priv->rx_entries, priv->tx_entries, priv->rx_fifo_limit,
				 (pause->rx_pause ? NET10G_PAUSE_RX : 0) |
				 (pause->tx_pause ? NET10G_PAUSE_TX : 0));
}

static const struct ethtool_ops frost_ethtool_ops = {
	.supported_coalesce_params = ETHTOOL_COALESCE_RX_USECS |
				     ETHTOOL_COALESCE_RX_MAX_FRAMES |
				     ETHTOOL_COALESCE_TX_USECS |
				     ETHTOOL_COALESCE_TX_MAX_FRAMES,
	.get_drvinfo	= frost_get_drvinfo,
	.get_link	= ethtool_op_get_link,
	.get_coalesce	= frost_get_coalesce,
	.set_coalesce	= frost_set_coalesce,
	.get_ringparam	= frost_get_ringparam,
	.set_ringparam	= frost_set_ringparam,
	.get_pauseparam	= frost_get_pauseparam,
	.set_pauseparam	= frost_set_pauseparam,
	.get_sset_count	= frost_get_sset_count,
	.get_strings	= frost_get_strings,
	.get_ethtool_stats = frost_get_ethtool_stats,
};

/*
 * Devlink runtime parameter rx_fifo_bytes: the RX ingress FIFO's occupancy limit in bytes
 * (8 bytes per word). ethtool has no knob for a MAC FIFO, so this driver-specific tunable is a
 * devlink parameter: devlink dev param set platform/<dev> name rx_fifo_bytes value N cmode runtime.
 * It reprograms the NIC through the same stop, rebuild and restart path as ethtool -G.
 */
enum {
	FROST_DEVLINK_PARAM_RX_FIFO_BYTES = DEVLINK_PARAM_GENERIC_ID_MAX + 1,
};

static struct frost_priv *frost_devlink_priv(struct devlink *devlink)
{
	return *(struct frost_priv **)devlink_priv(devlink);
}

static int frost_dl_rx_fifo_get(struct devlink *devlink, u32 id, struct devlink_param_gset_ctx *ctx)
{
	ctx->val.vu32 = frost_devlink_priv(devlink)->rx_fifo_limit * FROST_FIFO_WORD_BYTES;
	return 0;
}

static int frost_dl_rx_fifo_set(struct devlink *devlink, u32 id, struct devlink_param_gset_ctx *ctx,
				struct netlink_ext_ack *extack)
{
	struct frost_priv *priv = frost_devlink_priv(devlink);
	int err;

	rtnl_lock();
	err = frost_reconfigure(priv->ndev, priv->rx_entries, priv->tx_entries,
				ctx->val.vu32 / FROST_FIFO_WORD_BYTES, priv->pause);
	rtnl_unlock();
	return err;
}

static int frost_dl_rx_fifo_validate(struct devlink *devlink, u32 id, union devlink_param_value val,
				     struct netlink_ext_ack *extack)
{
	struct frost_priv *priv = frost_devlink_priv(devlink);
	u32 min = FROST_FIFO_LIMIT_MIN * FROST_FIFO_WORD_BYTES;
	u32 max = priv->rx_fifo_depth * FROST_FIFO_WORD_BYTES;

	if (val.vu32 % FROST_FIFO_WORD_BYTES || val.vu32 < min || val.vu32 > max) {
		NL_SET_ERR_MSG_FMT_MOD(extack, "rx_fifo_bytes must be a multiple of %u from %u to %u",
				       FROST_FIFO_WORD_BYTES, min, max);
		return -EINVAL;
	}
	return 0;
}

static const struct devlink_param frost_devlink_params[] = {
	DEVLINK_PARAM_DRIVER(FROST_DEVLINK_PARAM_RX_FIFO_BYTES, "rx_fifo_bytes",
			     DEVLINK_PARAM_TYPE_U32, BIT(DEVLINK_PARAM_CMODE_RUNTIME),
			     frost_dl_rx_fifo_get, frost_dl_rx_fifo_set, frost_dl_rx_fifo_validate),
};

static const struct devlink_ops frost_devlink_ops;

static void frost_devlink_free(void *data)
{
	devlink_free(data);
}

static void frost_devlink_unregister(void *data)
{
	struct devlink *devlink = data;

	devl_lock(devlink);
	devl_unregister(devlink);
	devl_params_unregister(devlink, frost_devlink_params, ARRAY_SIZE(frost_devlink_params));
	devl_unlock(devlink);
}

static int frost_devlink_init(struct frost_priv *priv)
{
	struct device *dev = priv->dev;
	struct devlink *devlink;
	int err;

	devlink = devlink_alloc(&frost_devlink_ops, sizeof(struct frost_priv *), dev);
	if (!devlink)
		return -ENOMEM;
	*(struct frost_priv **)devlink_priv(devlink) = priv;
	err = devm_add_action_or_reset(dev, frost_devlink_free, devlink);
	if (err)
		return err;

	devl_lock(devlink);
	err = devl_params_register(devlink, frost_devlink_params, ARRAY_SIZE(frost_devlink_params));
	if (!err)
		devl_register(devlink);
	devl_unlock(devlink);
	if (err)
		return err;
	priv->devlink = devlink;
	/* Runs before the free above, and after the netdev is unregistered */
	return devm_add_action_or_reset(dev, frost_devlink_unregister, devlink);
}

static int frost_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct net_device *ndev;
	struct frost_priv *priv;
	void __iomem *base;
	bool wide_abi = false;
	int irq, err;
	u32 id;

	base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(base))
		return PTR_ERR(base);

	id = readl(base + NET10G_ID);
	if (id != NET10G_ID_VALUE)
		return dev_err_probe(dev, -ENODEV, "unexpected ID %#x\n", id);

	irq = platform_get_irq(pdev, 0);
	if (irq < 0)
		return irq;

	/* Prefer the versioned 64-bit ABI; old hardware keeps its 32-bit mask. */
	if (readl(base + NET10G_ABI_CTRL) & NET10G_ABI_EXTENDED_SUPPORTED) {
		err = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(64));
		if (!err)
			wide_abi = true;
		else
			dev_warn(dev, "64-bit DMA mask unavailable; using legacy NIC mode\n");
	}
	if (!wide_abi) {
		err = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
		if (err)
			return dev_err_probe(dev, err, "no usable DMA mask\n");
	}

	ndev = devm_alloc_etherdev(dev, sizeof(*priv));
	if (!ndev)
		return -ENOMEM;
	SET_NETDEV_DEV(ndev, dev);
	platform_set_drvdata(pdev, ndev);

	priv = netdev_priv(ndev);
	priv->ndev = ndev;
	priv->dev = dev;
	priv->base = base;
	priv->irq = irq;
	priv->wide_abi = wide_abi;
	priv->csum_abi = !!(readl(base + NET10G_ABI_CTRL) & NET10G_ABI_CSUM_SUPPORTED);
	priv->sg_abi = !!(readl(base + NET10G_ABI_CTRL) & NET10G_ABI_TX_LONG_SEGMENTS);
	priv->segment_abi = priv->sg_abi && priv->csum_abi &&
			    !!(readl(base + NET10G_ABI_CTRL) & NET10G_ABI_SEGMENT_SUPPORTED);
	priv->rx_fifo_depth = readl(base + NET10G_RX_FIFO_DEPTH);
	priv->pause_abi = !!(readl(base + NET10G_ABI_CTRL) & NET10G_ABI_PAUSE_SUPPORTED);
	priv->tx_desc_max = (readl(base + NET10G_ABI_CTRL) & NET10G_ABI_TX_LONG_SEGMENTS) ?
			    FIELD_MAX(NET10G_DESC_LEN) : FROST_TX_DESC_MAX;
	priv->rx_fifo_limit = min(priv->rx_fifo_depth, (u32)FROST_FIFO_LIMIT_DEFAULT);
	priv->rx_entries = FROST_RING_DEFAULT;
	priv->tx_entries = FROST_RING_DEFAULT;
	spin_lock_init(&priv->ctrl_lock);
	u64_stats_init(&priv->rx_syncp);
	u64_stats_init(&priv->tx_syncp);

	err = of_get_ethdev_address(dev->of_node, ndev);
	if (err == -EPROBE_DEFER)
		return err;
	if (err)
		eth_hw_addr_random(ndev);

	ndev->netdev_ops = &frost_netdev_ops;
	ndev->ethtool_ops = &frost_ethtool_ops;
	ndev->min_mtu = ETH_MIN_MTU;
	ndev->max_mtu = FROST_MAX_MTU;
	/* MAC or PMA loopback, chosen by open from PHY_STATUS.CLK_SHARED */
	ndev->hw_features |= NETIF_F_LOOPBACK;
	/* Older NICs require FIRST and LAST on the same descriptor. */
	if (priv->sg_abi) {
		ndev->hw_features |= NETIF_F_SG;
		ndev->features |= NETIF_F_SG;
	}
	/* The descriptors hold a 64-bit buffer address in the extended layout */
	if (priv->wide_abi)
		ndev->features |= NETIF_F_HIGHDMA;
	if (priv->csum_abi) {
		/* TX: the NIC inserts the sum named in the first descriptor; RX: CHECKSUM_COMPLETE */
		ndev->hw_features |= NETIF_F_HW_CSUM | NETIF_F_RXCSUM;
		ndev->features |= NETIF_F_HW_CSUM | NETIF_F_RXCSUM;
	}
	if (priv->segment_abi) {
		/* Frame segmentation: the NIC takes up to 64 KB of payload per parameter descriptor */
		ndev->hw_features |= NETIF_F_TSO | NETIF_F_TSO6;
		ndev->features |= NETIF_F_TSO | NETIF_F_TSO6;
		netif_set_tso_max_size(ndev, FIELD_MAX(NET10G_PARAM_PAYLOAD));
	}

	netif_napi_add(ndev, &priv->napi, frost_poll);
	timer_setup(&priv->refill_timer, frost_refill_timer, 0);
	priv->rx_coalesce = FIELD_PREP(NET10G_COALESCE_DELAY, FROST_RX_COALESCE_US) |
			    FIELD_PREP(NET10G_COALESCE_FRAMES, FROST_RX_COALESCE_FRAMES);
	priv->tx_coalesce = FIELD_PREP(NET10G_COALESCE_DELAY, FROST_TX_COALESCE_US) |
			    FIELD_PREP(NET10G_COALESCE_FRAMES, FROST_TX_COALESCE_FRAMES);

	writel(NET10G_IRQ_ALL, base + NET10G_IRQ_MASK_CLR);
	err = devm_request_irq(dev, irq, frost_irq, 0, dev_name(dev), priv);
	if (err)
		return dev_err_probe(dev, err, "cannot request IRQ %d\n", irq);

	netif_carrier_off(ndev);
	if (priv->rx_fifo_depth) {
		err = frost_devlink_init(priv);
		if (err)
			return dev_err_probe(dev, err, "cannot register devlink\n");
	}
	err = devm_register_netdev(dev, ndev);
	if (err)
		return dev_err_probe(dev, err, "cannot register netdev\n");

	netdev_info(ndev, "FROST net10g, IRQ %d, MAC %pM, %s DMA ABI\n", irq,
		    ndev->dev_addr, priv->wide_abi ? "extended" : "legacy");
	return 0;
}

static const struct of_device_id frost_of_match[] = {
	{ .compatible = "frost,net10g" },
	{ }
};
MODULE_DEVICE_TABLE(of, frost_of_match);

static struct platform_driver frost_driver = {
	.probe = frost_probe,
	.driver = {
		.name = KBUILD_MODNAME,
		.of_match_table = frost_of_match,
		.suppress_bind_attrs = true,
	},
};
module_platform_driver(frost_driver);

MODULE_DESCRIPTION("FROST net10g 10GBASE-R Ethernet driver");
/* The DKMS package version: PACKAGE_VERSION in dkms.conf matches it */
MODULE_VERSION("1.1");
MODULE_LICENSE("Dual BSD/GPL");
