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
 * Every register access is readl() or writel() at a 4-aligned offset. The
 * register bus replicates an 8- or 16-bit store over the whole 32-bit
 * register (writeb(1, CTRL) would issue RESET), and a 64-bit store writes
 * only the upper register of its dword.
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
 * The driver assumes one CPU, the SoC's single hart, whether the kernel is
 * built uniprocessor or SMP: xmit and NAPI never interleave, and open and stop
 * touch the rings only while NAPI is disabled.
 *
 * The source is built as a module for Debian's kernel (6.12 on Debian 13),
 * through DKMS on a Debian root and the same way for the kernel FROST packs, so
 * it uses only long-standing interfaces rather than the newest spelling of one.
 */

#include <linux/dma-mapping.h>
#include <linux/etherdevice.h>
#include <linux/ethtool.h>
#include <linux/if_vlan.h>
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
#include <linux/timer.h>
#include <linux/u64_stats_sync.h>
#include <linux/unaligned.h>
#include <net/netdev_queues.h>

/* Registers, 32 bits each */
#define NET10G_ID			0x000
#define NET10G_CTRL			0x004
#define NET10G_STATUS			0x008
#define NET10G_MAC_LO			0x00c
#define NET10G_MAC_HI			0x010
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

/* Descriptor word 1 (TX frame flags) and word 2 (status, written by the NIC) */
#define NET10G_DESC_TX_SOP		BIT(16)
#define NET10G_DESC_TX_EOP		BIT(17)
#define NET10G_DESC_LEN			GENMASK(15, 0)
#define NET10G_DESC_DD			BIT(16)
#define NET10G_DESC_TRUNC		BIT(17)
#define NET10G_DESC_ERR			BIT(18)
#define NET10G_DESC_ABORT		BIT(19)

/* Both rings: 128 entries, so at most 127 posted (TAIL == HEAD is empty) */
#define FROST_RING_LOG2			7
#define FROST_RING_ENTRIES		BIT(FROST_RING_LOG2)
#define FROST_RING_MASK			(FROST_RING_ENTRIES - 1)
#define FROST_RING_BYTES \
	(FROST_RING_ENTRIES * sizeof(struct frost_desc))
#define FROST_RING_ALIGN_MASK		31	/* BASE is 32-byte aligned */

#define FROST_MAX_MTU			9000
#define FROST_POLL_US			1000
#define FROST_RESET_TIMEOUT_US		USEC_PER_SEC
#define FROST_ENABLE_TRIES		3
#define FROST_REFILL_MS			100

/* One ring descriptor: 16 bytes, two per 32-byte line */
struct frost_desc {
	__le32 addr;		/* buffer DMA address */
	__le32 len;		/* RX: buffer length; TX: length | SOP | EOP */
	__le32 status;		/* written by the NIC */
	__le32 reserved;
};

struct frost_buf {
	struct sk_buff *skb;
	dma_addr_t dma;
	unsigned int len;	/* the mapped length */
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
	unsigned long reenables;	/* CTRL rewrites after a READY loss */

	unsigned int rx_buf_len;
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

static u32 frost_tx_free(const struct frost_priv *priv)
{
	return FROST_RING_MASK -
	       ((priv->tx_head - priv->tx_clean) & FROST_RING_MASK);
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
 * Request a poll from outside the hard interrupt handler (open's link refresh
 * and the refill timer): mask, flush the store with a read, then schedule, so
 * the device is masked from the request on, as after an interrupt.
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
 * Post RX buffers at rx_tail until 127 are outstanding or an allocation or
 * mapping fails; return how many this call posted. Only the slot at rx_tail
 * is written, never a descriptor the NIC may already hold. The NIC uses a
 * descriptor only from a read accepted after TAIL covered it, and dma_wmb()
 * orders the four word stores ahead of the doorbell store, so that read sees
 * the posted words.
 */
static unsigned int frost_rx_fill(struct frost_priv *priv, gfp_t gfp)
{
	unsigned int posted = 0;

	while (((priv->rx_tail + 1) & FROST_RING_MASK) != priv->rx_clean) {
		struct frost_desc *desc = &priv->rx_ring[priv->rx_tail];
		struct frost_buf *buf = &priv->rx_bufs[priv->rx_tail];
		struct sk_buff *skb;
		dma_addr_t dma;

		skb = __netdev_alloc_skb_ip_align(priv->ndev, priv->rx_buf_len,
						  gfp);
		if (!skb)
			break;
		dma = dma_map_single(priv->dev, skb->data, priv->rx_buf_len,
				     DMA_FROM_DEVICE);
		if (dma_mapping_error(priv->dev, dma)) {
			dev_kfree_skb_any(skb);
			break;
		}
		buf->skb = skb;
		buf->dma = dma;
		buf->len = priv->rx_buf_len;

		desc->addr = cpu_to_le32(lower_32_bits(dma));
		desc->len = cpu_to_le32(priv->rx_buf_len);
		desc->status = 0;
		desc->reserved = 0;
		priv->rx_tail = (priv->rx_tail + 1) & FROST_RING_MASK;
		posted++;
	}

	if (posted) {
		dma_wmb();
		writel(priv->rx_tail, priv->base + NET10G_RX_TAIL);
	}
	return posted;
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
		u32 status = le32_to_cpu(READ_ONCE(desc->status));

		/*
		 * The NIC writes DD once every buffer read it issued has
		 * returned: the whole frame, or less with ERR or ABORT.
		 */
		if (!(status & NET10G_DESC_DD))
			break;
		dma_unmap_single(priv->dev, buf->dma, buf->len, DMA_TO_DEVICE);
		pkts++;
		bytes += buf->len;
		if (status & (NET10G_DESC_ERR | NET10G_DESC_ABORT)) {
			errors++;
		} else {
			good++;
			good_bytes += buf->len;
		}
		napi_consume_skb(buf->skb, budget);
		buf->skb = NULL;
		priv->tx_clean = (priv->tx_clean + 1) & FROST_RING_MASK;
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
		u32 status = le32_to_cpu(READ_ONCE(desc->status));
		u32 len = status & NET10G_DESC_LEN;
		struct sk_buff *skb = buf->skb;

		if (!(status & NET10G_DESC_DD))
			break;
		/*
		 * DD and the length come from the one load above. The NIC
		 * writes the status only after every data write it issued for
		 * the frame has been answered; dma_rmb() orders the frame data
		 * loads (eth_type_trans() reads the header) after that load.
		 */
		dma_rmb();
		dma_unmap_single(priv->dev, buf->dma, buf->len,
				 DMA_FROM_DEVICE);
		buf->skb = NULL;
		priv->rx_clean = (priv->rx_clean + 1) & FROST_RING_MASK;
		work++;

		if ((status & (NET10G_DESC_TRUNC | NET10G_DESC_ERR |
			       NET10G_DESC_ABORT)) ||
		    len < ETH_HLEN || len > buf->len) {
			errors++;
			dev_kfree_skb_any(skb);
			continue;
		}
		skb_put(skb, len);
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
 * Re-enable the directions the NIC disabled on its own. While the interface
 * runs, CTRL shows a direction disabled only after its MAC domain lost READY.
 * Once STATUS shows that direction READY again, one CTRL write with both
 * enables and PROMISC is accepted for it, since its ring registers are still
 * valid, and the NIC resumes fetching descriptors at HEAD. A direction that is
 * disabled and still not READY is refused by that write (CONFIG_ERR and a
 * masked DESC_ERR event) and is retried at the LINK event that follows its
 * READY return. Only the poll calls this, and the poll never runs while open
 * or stop has RESET in progress, so the write is never dropped as busy.
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
	 * Acknowledge before scanning. RX and TX are moderated notifications:
	 * writing 1 starts a new interval, and a completion after that write
	 * raises the bit again (ITR 0, the reset value, raises on the first
	 * completion). A completion before the acknowledgment is found by the
	 * scans below; one after it raises its bit, which asserts the line when
	 * this poll unmasks. Acknowledging after the final scan could erase a
	 * completion the scan missed. The read flushes the acknowledgment, so
	 * every descriptor load below comes after it.
	 */
	st = readl(priv->base + NET10G_IRQ_STATUS);
	writel(st | NET10G_IRQ_RX | NET10G_IRQ_TX,
	       priv->base + NET10G_IRQ_STATUS);
	readl(priv->base + NET10G_IRQ_STATUS);

	/*
	 * The carrier has one writer, this poll. LINK is read after the
	 * acknowledgment, so a later change raises the event again. A MAC
	 * domain restart drops the carrier, and the event for its return comes
	 * only after READY has returned, so the event is also where a direction
	 * that lost READY is re-enabled.
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
		dma_free_coherent(priv->dev, FROST_RING_BYTES, priv->rx_ring,
				  priv->rx_ring_dma);
	if (priv->tx_ring)
		dma_free_coherent(priv->dev, FROST_RING_BYTES, priv->tx_ring,
				  priv->tx_ring_dma);
	kfree(priv->rx_bufs);
	kfree(priv->tx_bufs);
	priv->rx_ring = NULL;
	priv->tx_ring = NULL;
	priv->rx_bufs = NULL;
	priv->tx_bufs = NULL;
}

static int frost_alloc_rings(struct frost_priv *priv)
{
	/* dma_alloc_coherent() returns zeroed, page-aligned memory */
	priv->rx_ring = dma_alloc_coherent(priv->dev, FROST_RING_BYTES,
					   &priv->rx_ring_dma, GFP_KERNEL);
	priv->tx_ring = dma_alloc_coherent(priv->dev, FROST_RING_BYTES,
					   &priv->tx_ring_dma, GFP_KERNEL);
	priv->rx_bufs = kcalloc(FROST_RING_ENTRIES, sizeof(*priv->rx_bufs),
				GFP_KERNEL);
	priv->tx_bufs = kcalloc(FROST_RING_ENTRIES, sizeof(*priv->tx_bufs),
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
 * RESET the NIC, then free what was published to it. RESET drains the NIC's
 * DMA path: RESET_BUSY clears only once no request the NIC issued still owes
 * a response, and after that nothing further can be issued, so only then may
 * published memory be unmapped and freed. The caller has already stopped
 * every other writer to the NIC (xmit, NAPI, the refill timer and the
 * interrupt), since configuration writes are dropped while RESET is busy.
 * A RESET that does not complete never authorizes a free: the rings and every
 * posted buffer are leaked, and the device is marked broken and detached.
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
		netif_device_detach(ndev);
		netif_carrier_off(ndev);
		return;
	}

	while (priv->rx_clean != priv->rx_tail) {
		struct frost_buf *buf = &priv->rx_bufs[priv->rx_clean];

		dma_unmap_single(priv->dev, buf->dma, buf->len,
				 DMA_FROM_DEVICE);
		dev_kfree_skb(buf->skb);
		buf->skb = NULL;
		priv->rx_clean = (priv->rx_clean + 1) & FROST_RING_MASK;
	}

	while (priv->tx_clean != priv->tx_head) {
		struct frost_buf *buf = &priv->tx_bufs[priv->tx_clean];

		dma_unmap_single(priv->dev, buf->dma, buf->len, DMA_TO_DEVICE);
		dev_kfree_skb(buf->skb);
		buf->skb = NULL;
		priv->tx_clean = (priv->tx_clean + 1) & FROST_RING_MASK;
		dropped++;
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
 * Stop the poll, the refill timer and the interrupt, as frost_reset_and_free()
 * requires. Stop does this, and so does open when it fails after enabling
 * NAPI: busy polling can run the poll with no interrupt, and a poll can arm
 * the refill timer and unmask the device.
 */
static void frost_quiesce(struct frost_priv *priv)
{
	/* The poll is the only place the refill timer is armed */
	napi_disable(&priv->napi);
	timer_delete_sync(&priv->refill_timer);

	writel(NET10G_IRQ_ALL, priv->base + NET10G_IRQ_MASK_CLR);
	readl(priv->base + NET10G_IRQ_MASK);
	synchronize_irq(priv->irq);
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

	priv->rx_clean = 0;
	priv->rx_tail = 0;
	priv->tx_clean = 0;
	priv->tx_head = 0;
	priv->rx_buf_len = ndev->mtu + ETH_HLEN + VLAN_HLEN;

	/* Bookkeeping comes back zeroed: no skb recorded in any slot */
	err = frost_alloc_rings(priv);
	if (err)
		return err;

	/*
	 * PHY_CTRL before RESET. MAC loopback needs one clock for both MAC
	 * directions (PHY_STATUS.CLK_SHARED) and is sampled while the RX MAC
	 * domain is in reset, so this RESET applies it. PMA loopback is the
	 * transceiver's: a change restarts its receiver, which takes READY
	 * down until the receiver is back, possibly only after the wait for
	 * READY below has passed; the enable step allows for that. Nothing
	 * else is written until RESET_BUSY clears, because configuration
	 * writes are dropped while it is set; READY returns only after that
	 * and is awaited separately.
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
		 * Nothing of this open reached the NIC, and the previous stop
		 * completed its own RESET, so the rings may be freed. The
		 * device is detached as in frost_reset_and_free().
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
	writel(lower_32_bits(priv->rx_ring_dma), priv->base + NET10G_RX_BASE);
	writel(FROST_RING_LOG2, priv->base + NET10G_RX_SIZE);
	writel(lower_32_bits(priv->tx_ring_dma), priv->base + NET10G_TX_BASE);
	writel(FROST_RING_LOG2, priv->base + NET10G_TX_SIZE);
	if (readl(priv->base + NET10G_RX_BASE) !=
	    lower_32_bits(priv->rx_ring_dma) ||
	    readl(priv->base + NET10G_RX_SIZE) != FROST_RING_LOG2 ||
	    readl(priv->base + NET10G_TX_BASE) !=
	    lower_32_bits(priv->tx_ring_dma) ||
	    readl(priv->base + NET10G_TX_SIZE) != FROST_RING_LOG2) {
		netdev_err(ndev, "ring registers not accepted\n");
		err = -EIO;
		goto err_reset;
	}

	/* An empty RX ring would never produce the poll that refills it */
	if (!frost_rx_fill(priv, GFP_KERNEL)) {
		err = -ENOMEM;
		goto err_reset;
	}

	writel(NET10G_IRQ_ALL, priv->base + NET10G_IRQ_STATUS);
	napi_enable(&priv->napi);

	spin_lock_bh(&priv->ctrl_lock);
	priv->promisc = !!(ndev->flags & IFF_PROMISC);
	priv->running = true;
	writel(frost_ctrl_value(priv), priv->base + NET10G_CTRL);
	spin_unlock_bh(&priv->ctrl_lock);

	/*
	 * An enable is refused unless its direction is READY and its ring
	 * valid. The ring registers were read back above, but READY may have
	 * fallen since the wait for it (a transceiver restarting its receiver
	 * for a PMA loopback change), so wait for READY again and repeat the
	 * write, a bounded number of times.
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

	/*
	 * The core has cleared netif_running() and deactivated the qdisc:
	 * xmit is over and completions no longer wake the queue.
	 */
	netif_tx_disable(ndev);
	spin_lock_bh(&priv->ctrl_lock);
	priv->running = false;
	spin_unlock_bh(&priv->ctrl_lock);

	frost_quiesce(priv);
	frost_reset_and_free(priv);
	return 0;
}

static netdev_tx_t frost_start_xmit(struct sk_buff *skb,
				    struct net_device *ndev)
{
	struct frost_priv *priv = netdev_priv(ndev);
	struct netdev_queue *txq = netdev_get_tx_queue(ndev, 0);
	struct frost_desc *desc;
	struct frost_buf *buf;
	dma_addr_t dma;

	/* The queue stops at 0 free descriptors, so this should not happen */
	if (unlikely(!frost_tx_free(priv))) {
		netif_stop_subqueue(ndev, 0);
		return NETDEV_TX_BUSY;
	}

	dma = dma_map_single(priv->dev, skb->data, skb->len, DMA_TO_DEVICE);
	if (unlikely(dma_mapping_error(priv->dev, dma))) {
		dev_kfree_skb_any(skb);
		u64_stats_update_begin(&priv->tx_syncp);
		u64_stats_inc(&priv->tx_dropped);
		u64_stats_update_end(&priv->tx_syncp);
		return NETDEV_TX_OK;
	}

	/*
	 * No padding: the MAC pads short frames to 60 bytes. The four word
	 * stores precede dma_wmb() and the doorbell, as for RX.
	 */
	desc = &priv->tx_ring[priv->tx_head];
	buf = &priv->tx_bufs[priv->tx_head];
	desc->addr = cpu_to_le32(lower_32_bits(dma));
	desc->len = cpu_to_le32(skb->len | NET10G_DESC_TX_SOP |
				NET10G_DESC_TX_EOP);
	desc->status = 0;
	desc->reserved = 0;
	buf->skb = skb;
	buf->dma = dma;
	buf->len = skb->len;

	netdev_tx_sent_queue(txq, buf->len);
	priv->tx_head = (priv->tx_head + 1) & FROST_RING_MASK;
	dma_wmb();
	writel(priv->tx_head, priv->base + NET10G_TX_TAIL);

	netif_subqueue_maybe_stop(ndev, 0, frost_tx_free(priv), 1, 1);
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
	 * Loopback, MAC or PMA, takes effect through the RESET that only open
	 * issues. While down, the core records the new features and the next
	 * open applies them.
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
};

static void frost_get_drvinfo(struct net_device *ndev,
			      struct ethtool_drvinfo *info)
{
	struct frost_priv *priv = netdev_priv(ndev);

	strscpy(info->driver, KBUILD_MODNAME, sizeof(info->driver));
	strscpy(info->bus_info, dev_name(priv->dev), sizeof(info->bus_info));
}

static const struct ethtool_ops frost_ethtool_ops = {
	.get_drvinfo	= frost_get_drvinfo,
	.get_link	= ethtool_op_get_link,
};

static int frost_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct net_device *ndev;
	struct frost_priv *priv;
	void __iomem *base;
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

	/*
	 * The NIC reaches [0x80000000, 0xc0000000). A 32-bit mask does not
	 * express that aperture; the SoC's memory lies inside it.
	 */
	err = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
	if (err)
		return dev_err_probe(dev, err, "no usable DMA mask\n");

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

	netif_napi_add(ndev, &priv->napi, frost_poll);
	timer_setup(&priv->refill_timer, frost_refill_timer, 0);

	writel(NET10G_IRQ_ALL, base + NET10G_IRQ_MASK_CLR);
	err = devm_request_irq(dev, irq, frost_irq, 0, dev_name(dev), priv);
	if (err)
		return dev_err_probe(dev, err, "cannot request IRQ %d\n", irq);

	netif_carrier_off(ndev);
	err = devm_register_netdev(dev, ndev);
	if (err)
		return dev_err_probe(dev, err, "cannot register netdev\n");

	netdev_info(ndev, "FROST net10g, IRQ %d, MAC %pM\n", irq,
		    ndev->dev_addr);
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
MODULE_VERSION("1.0");
MODULE_LICENSE("Dual BSD/GPL");
