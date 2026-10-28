// SPDX-License-Identifier: GPL-2.0+
/*
 * FROST 10G / 1G Ethernet MAC U-Boot Driver
 *
 * Copyright (c) 2026 John Goodacre
 *
 * DM_ETH driver for FROST coherent-DMA network interface (compatible = "frost,net10g").
 * Used in U-Boot Proper on VCU118 for DHCP, TFTP, and network boot.
 */

#include <dm.h>
#include <net.h>
#include <malloc.h>
#include <asm/io.h>
#include <linux/delay.h>
#include <linux/iopoll.h>

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
#define NET10G_LINK			0x060
#define NET10G_PHY_CTRL			0x064
#define NET10G_PHY_STATUS		0x068
#define NET10G_ABI_CTRL			0x06c

#define NET10G_ID_VALUE			0x4e494301

#define NET10G_CTRL_RX_EN		BIT(0)
#define NET10G_CTRL_TX_EN		BIT(1)
#define NET10G_CTRL_PROMISC		BIT(2)
#define NET10G_CTRL_RESET		BIT(8)

#define NET10G_STATUS_RESET_BUSY	BIT(2)
#define NET10G_STATUS_RX_READY		BIT(4)
#define NET10G_STATUS_TX_READY		BIT(5)
#define NET10G_LINK_CARRIER		BIT(8)

#define NET10G_DESC_TX_SOP		BIT(16)
#define NET10G_DESC_TX_EOP		BIT(17)
#define NET10G_DESC_DD			BIT(16)
#define NET10G_DESC_TRUNC		BIT(17)
#define NET10G_DESC_ERR			BIT(18)
#define NET10G_DESC_ABORT		BIT(19)

#define FROST_RING_LOG2			4
#define FROST_RING_ENTRIES		(1u << FROST_RING_LOG2) /* 16 */
#define FROST_RING_MASK			(FROST_RING_ENTRIES - 1)
#define PKT_BUF_SZ			2048

struct frost_desc {
	u32 word0;
	u32 word1;
	u32 word2;
	u32 word3;
};

struct frost_net10g_priv {
	void __iomem *base;
	struct frost_desc *rx_ring;
	struct frost_desc *tx_ring;
	u8 *rx_buffers;
	u8 *tx_buffers;
	u32 rx_clean;
	u32 rx_tail;
	u32 tx_head;
};

static inline void frost_sync(void)
{
	__asm__ volatile("fence rw, rw" ::: "memory");
}

static int frost_net10g_write_hwaddr(struct udevice *dev)
{
	struct frost_net10g_priv *priv = dev_get_priv(dev);
	struct eth_pdata *pdata = dev_get_plat(dev);
	const u8 *ea = pdata->enetaddr;

	u32 lo = ea[0] | (ea[1] << 8) | (ea[2] << 16) | ((u32)ea[3] << 24);
	u32 hi = ea[4] | (ea[5] << 8);

	writel(lo, priv->base + NET10G_MAC_LO);
	writel(hi, priv->base + NET10G_MAC_HI);
	return 0;
}

static int frost_net10g_start(struct udevice *dev)
{
	struct frost_net10g_priv *priv = dev_get_priv(dev);
	u32 status;
	int ret;

	/* Reset device */
	writel(0, priv->base + NET10G_PHY_CTRL);
	writel(NET10G_CTRL_RESET, priv->base + NET10G_CTRL);

	ret = readl_poll_timeout(priv->base + NET10G_STATUS, status,
				 !(status & NET10G_STATUS_RESET_BUSY), 500000);
	if (ret) {
		printf("%s: reset timeout\n", dev->name);
		return ret;
	}

	ret = readl_poll_timeout(priv->base + NET10G_STATUS, status,
				 (status & (NET10G_STATUS_RX_READY | NET10G_STATUS_TX_READY)) ==
				 (NET10G_STATUS_RX_READY | NET10G_STATUS_TX_READY),
				 500000);
	if (ret) {
		printf("%s: MAC ready timeout (STATUS=0x%08x)\n", dev->name, status);
		return ret;
	}

	frost_net10g_write_hwaddr(dev);

	/* Set 32-bit legacy descriptor mode */
	writel(0, priv->base + NET10G_ABI_CTRL);

	/* Initialize ring descriptors and pointers */
	memset(priv->rx_ring, 0, FROST_RING_ENTRIES * sizeof(struct frost_desc));
	memset(priv->tx_ring, 0, FROST_RING_ENTRIES * sizeof(struct frost_desc));
	priv->rx_clean = 0;
	priv->rx_tail = 0;
	priv->tx_head = 0;

	writel((u32)(uintptr_t)priv->rx_ring, priv->base + NET10G_RX_BASE);
	writel((u32)(uintptr_t)priv->tx_ring, priv->base + NET10G_TX_BASE);
	writel(FROST_RING_LOG2, priv->base + NET10G_RX_SIZE);
	writel(FROST_RING_LOG2, priv->base + NET10G_TX_SIZE);

	/* Populate RX ring with buffers (entries 0 .. FROST_RING_ENTRIES - 2) */
	for (u32 i = 0; i < FROST_RING_ENTRIES - 1; i++) {
		priv->rx_ring[i].word0 = (u32)(uintptr_t)(priv->rx_buffers + i * PKT_BUF_SZ);
		priv->rx_ring[i].word1 = PKT_BUF_SZ;
		priv->rx_ring[i].word2 = 0;
		priv->rx_ring[i].word3 = 0;
	}
	priv->rx_tail = FROST_RING_ENTRIES - 1;
	frost_sync();
	writel(priv->rx_tail, priv->base + NET10G_RX_TAIL);

	/* Enable RX, TX, and promiscuous mode */
	writel(NET10G_CTRL_RX_EN | NET10G_CTRL_TX_EN | NET10G_CTRL_PROMISC,
	       priv->base + NET10G_CTRL);

	/* Poll link carrier for up to 3 seconds */
	ret = readl_poll_timeout(priv->base + NET10G_LINK, status,
				 (status & NET10G_LINK_CARRIER), 3000000);
	if (ret) {
		printf("%s: link carrier down (LINK=0x%08x)\n", dev->name, status);
		return -ENETDOWN;
	}

	return 0;
}

static void frost_net10g_stop(struct udevice *dev)
{
	struct frost_net10g_priv *priv = dev_get_priv(dev);
	u32 status;

	writel(NET10G_CTRL_RESET, priv->base + NET10G_CTRL);
	(void)readl_poll_timeout(priv->base + NET10G_STATUS, status,
				 !(status & NET10G_STATUS_RESET_BUSY), 100000);
}

static int frost_net10g_send(struct udevice *dev, void *packet, int length)
{
	struct frost_net10g_priv *priv = dev_get_priv(dev);
	u32 slot = priv->tx_head;
	u32 status;
	int ret;

	if (length <= 0 || length > PKT_BUF_SZ)
		return -EINVAL;

	memcpy(priv->tx_buffers + slot * PKT_BUF_SZ, packet, length);

	priv->tx_ring[slot].word0 = (u32)(uintptr_t)(priv->tx_buffers + slot * PKT_BUF_SZ);
	priv->tx_ring[slot].word1 = (u32)length | NET10G_DESC_TX_SOP | NET10G_DESC_TX_EOP;
	priv->tx_ring[slot].word2 = 0;
	priv->tx_ring[slot].word3 = 0;

	priv->tx_head = (priv->tx_head + 1) & FROST_RING_MASK;
	frost_sync();
	writel(priv->tx_head, priv->base + NET10G_TX_TAIL);

	/* Wait for TX descriptor completion */
	ret = readl_poll_timeout(&priv->tx_ring[slot].word2, status,
				 (status & NET10G_DESC_DD), 100000);
	if (ret)
		return -ETIMEDOUT;

	if (status & (NET10G_DESC_ERR | NET10G_DESC_ABORT))
		return -EIO;

	return 0;
}

static int frost_net10g_recv(struct udevice *dev, int flags, uchar **packetp)
{
	struct frost_net10g_priv *priv = dev_get_priv(dev);
	u32 slot = priv->rx_clean;
	u32 status = priv->rx_ring[slot].word2;

	if (!(status & NET10G_DESC_DD))
		return -EAGAIN;

	frost_sync();
	u32 len = status & 0xFFFF;
	*packetp = (uchar *)(uintptr_t)priv->rx_ring[slot].word0;

	if (status & (NET10G_DESC_TRUNC | NET10G_DESC_ERR | NET10G_DESC_ABORT))
		return -EIO;

	return (int)len;
}

static int frost_net10g_free_pkt(struct udevice *dev, uchar *packet, int length)
{
	struct frost_net10g_priv *priv = dev_get_priv(dev);
	u32 tail = priv->rx_tail;

	/* Recycle descriptor */
	priv->rx_ring[tail].word0 = (u32)(uintptr_t)packet;
	priv->rx_ring[tail].word1 = PKT_BUF_SZ;
	priv->rx_ring[tail].word2 = 0;
	priv->rx_ring[tail].word3 = 0;

	priv->rx_clean = (priv->rx_clean + 1) & FROST_RING_MASK;
	priv->rx_tail = (priv->rx_tail + 1) & FROST_RING_MASK;

	frost_sync();
	writel(priv->rx_tail, priv->base + NET10G_RX_TAIL);
	return 0;
}

static const struct eth_ops frost_net10g_ops = {
	.start        = frost_net10g_start,
	.send         = frost_net10g_send,
	.recv         = frost_net10g_recv,
	.free_pkt     = frost_net10g_free_pkt,
	.stop         = frost_net10g_stop,
	.write_hwaddr = frost_net10g_write_hwaddr,
};

static int frost_net10g_probe(struct udevice *dev)
{
	struct frost_net10g_priv *priv = dev_get_priv(dev);
	fdt_addr_t addr;

	addr = dev_read_addr(dev);
	if (addr == FDT_ADDR_T_NONE)
		return -EINVAL;

	priv->base = (void __iomem *)(uintptr_t)addr;
	if (readl(priv->base + NET10G_ID) != NET10G_ID_VALUE)
		return -ENODEV;

	priv->rx_ring = memalign(32, FROST_RING_ENTRIES * sizeof(struct frost_desc));
	priv->tx_ring = memalign(32, FROST_RING_ENTRIES * sizeof(struct frost_desc));
	priv->rx_buffers = memalign(64, FROST_RING_ENTRIES * PKT_BUF_SZ);
	priv->tx_buffers = memalign(64, FROST_RING_ENTRIES * PKT_BUF_SZ);

	if (!priv->rx_ring || !priv->tx_ring || !priv->rx_buffers || !priv->tx_buffers)
		return -ENOMEM;

	return 0;
}

static int frost_net10g_remove(struct udevice *dev)
{
	struct frost_net10g_priv *priv = dev_get_priv(dev);

	frost_net10g_stop(dev);
	free(priv->rx_ring);
	free(priv->tx_ring);
	free(priv->rx_buffers);
	free(priv->tx_buffers);
	return 0;
}

static const struct udevice_id frost_net10g_ids[] = {
	{ .compatible = "frost,net10g" },
	{ }
};

U_BOOT_DRIVER(frost_net10g) = {
	.name     = "frost_net10g",
	.id       = UCLASS_ETH,
	.of_match = frost_net10g_ids,
	.probe    = frost_net10g_probe,
	.remove   = frost_net10g_remove,
	.ops      = &frost_net10g_ops,
	.priv_auto = sizeof(struct frost_net10g_priv),
	.plat_auto = sizeof(struct eth_pdata),
};
