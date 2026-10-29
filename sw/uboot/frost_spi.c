// SPDX-License-Identifier: GPL-2.0+
/*
 * FROST SPI Controller Driver for U-Boot
 *
 * Copyright (c) 2026 John Goodacre
 *
 * DM_SPI driver for the memory-mapped FROST SPI Flash Controller
 * mapped at 0x40023000 (connected to Micron MT25QU01G SPI NOR flash).
 */

#include <errno.h>
#include <linux/kernel.h>
#include <dm.h>
#include <spi.h>
#include <asm/io.h>
#include <linux/iopoll.h>

#define SPI_CTRL_REG       0x0000
#define SYS_STATUS_REG     0x0004
#define SPI_XFER_BYTE_REG  0x0008
#define SPI_XFER_WORD_REG  0x000C

#define SPI_CTRL_CS_N      (1u << 0)
#define SPI_CTRL_CLK_DIV(d) (((u32)(d) & 0xFF) << 8)

#define SYS_STATUS_SPI_BUSY (1u << 0)

struct frost_spi_plat {
	void __iomem *regs;
};

struct frost_spi_priv {
	void __iomem *regs;
	u32 clk_div;	u32 clock_hz;
};

static int frost_spi_claim_bus(struct udevice *dev)
{
	struct frost_spi_priv *priv = dev_get_priv(dev->parent);

	/* Keep the flash deselected until SPI_XFER_BEGIN. */
	writel(SPI_CTRL_CLK_DIV(priv->clk_div) | SPI_CTRL_CS_N, priv->regs + SPI_CTRL_REG);
	return 0;
}

static int frost_spi_release_bus(struct udevice *dev)
{
	struct frost_spi_priv *priv = dev_get_priv(dev->parent);

	/* Deassert CS# (active low: write 1 to CS_N bit) */
	writel(SPI_CTRL_CLK_DIV(priv->clk_div) | SPI_CTRL_CS_N, priv->regs + SPI_CTRL_REG);
	return 0;
}

static int frost_spi_xfer(struct udevice *dev, unsigned int bitlen,
			  const void *dout, void *din, unsigned long flags)
{
	struct frost_spi_priv *priv = dev_get_priv(dev->parent);
	const u8 *tx = dout;
	u8 *rx = din;
	unsigned int bytes = bitlen / 8;
	u32 status;
	int ret;

	if (bitlen % 8)
		return -EINVAL;

	if (flags & SPI_XFER_BEGIN)
		writel(SPI_CTRL_CLK_DIV(priv->clk_div), priv->regs + SPI_CTRL_REG);

	for (unsigned int i = 0; i < bytes; i++) {
		u8 b_out = tx ? tx[i] : 0xFF;

		writel((u32)b_out, priv->regs + SPI_XFER_BYTE_REG);

		/* Wait for SPI transfer to finish */
		ret = readl_poll_timeout(priv->regs + SYS_STATUS_REG, status,
					 !(status & SYS_STATUS_SPI_BUSY), 100000);
		if (ret) {
			frost_spi_release_bus(dev);
			return ret;
		}

		if (rx)
			rx[i] = (u8)readl(priv->regs + SPI_XFER_BYTE_REG);
	}

	if (flags & SPI_XFER_END)
		frost_spi_release_bus(dev);

	return 0;
}

static int frost_spi_set_speed(struct udevice *bus, uint speed)
{
	struct frost_spi_priv *priv = dev_get_priv(bus);
	u64 div;

	if (!speed)
		return -EINVAL;
	div = ((u64)priv->clock_hz + 2ULL * speed - 1) / (2ULL * speed);
	/* Allow the input synchronizer to settle before each sample. */
	div = max_t(u64, 6, div);
	if (div > 255)
		return -EINVAL;
	priv->clk_div = div;
	writel(SPI_CTRL_CLK_DIV(priv->clk_div) | SPI_CTRL_CS_N, priv->regs + SPI_CTRL_REG);
	return 0;
}

static int frost_spi_set_mode(struct udevice *bus, uint mode)
{
	return mode ? -EINVAL : 0;
}

static const struct dm_spi_ops frost_spi_ops = {
	.claim_bus  = frost_spi_claim_bus,
	.release_bus = frost_spi_release_bus,
	.xfer       = frost_spi_xfer,
	.set_speed  = frost_spi_set_speed,
	.set_mode   = frost_spi_set_mode,
};

static int frost_spi_probe(struct udevice *bus)
{
	struct frost_spi_plat *plat = dev_get_plat(bus);
	struct frost_spi_priv *priv = dev_get_priv(bus);

	priv->regs = plat->regs;
	priv->clock_hz = dev_read_u32_default(bus, "clock-frequency", 0);
	if (!priv->clock_hz)
		return -EINVAL;
	priv->clk_div = 6;

	/* Deassert CS# initially */
	writel(SPI_CTRL_CLK_DIV(priv->clk_div) | SPI_CTRL_CS_N, priv->regs + SPI_CTRL_REG);
	return 0;
}

static int frost_spi_of_to_plat(struct udevice *bus)
{
	struct frost_spi_plat *plat = dev_get_plat(bus);

	plat->regs = (void __iomem *)(uintptr_t)dev_read_addr(bus);
	if (plat->regs == (void __iomem *)FDT_ADDR_T_NONE)
		return -EINVAL;

	return 0;
}

static const struct udevice_id frost_spi_ids[] = {
	{ .compatible = "frost,spi-flash" },
	{ .compatible = "frost,boot-spi" },
	{ }
};

U_BOOT_DRIVER(frost_spi) = {
	.name       = "frost_spi",
	.id         = UCLASS_SPI,
	.of_match   = frost_spi_ids,
	.ops        = &frost_spi_ops,
	.of_to_plat = frost_spi_of_to_plat,
	.plat_auto  = sizeof(struct frost_spi_plat),
	.priv_auto  = sizeof(struct frost_spi_priv),
	.probe      = frost_spi_probe,
};
