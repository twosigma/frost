// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
/*
 * FROST memory error unit driver
 *
 * Copyright 2026 Two Sigma Open Source, LLC
 *
 * The unit (hw/rtl/cpu_and_mem/memory_error_unit.sv in the FROST tree)
 * counts the DDR controller's corrected (CE) and uncorrectable (UE) ECC
 * errors, which a board-specific reader polls from the controller, and the
 * error responses DDR returns to the cache hierarchy. It keeps the physical
 * address of the latest ECC report of each kind and raises one level
 * interrupt for the kinds enabled in IRQ_EN.
 *
 * The driver enables every kind, logs each report, clears the status bits it
 * handled, and exposes the unit's counters as read-only sysfs attributes of
 * the device. STATUS also flags a newly captured address of each ECC kind,
 * so the log names an address only when the report came with one. A read that ends in
 * an error response still delivers its data, so the report is the only sign
 * of it; the kernel is not stopped.
 *
 * Registers are 32 bits, read with readl() and written with writel() at
 * 4-aligned offsets; the two 64-bit address registers are read with readq().
 * The register bus writes only the upper register of a 64-bit store's dword.
 */

#include <linux/bitfield.h>
#include <linux/bits.h>
#include <linux/device.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/platform_device.h>

#define MEMERR_CAPS 0x00
#define MEMERR_STATUS 0x04
#define MEMERR_IRQ_EN 0x08
#define MEMERR_CE_COUNT 0x10
#define MEMERR_UE_COUNT 0x14
#define MEMERR_AXI_RD_ERRS 0x18
#define MEMERR_AXI_WR_ERRS 0x1c
#define MEMERR_CE_ADDR 0x20
#define MEMERR_UE_ADDR 0x28
#define MEMERR_AXI_ERR 0x30
#define MEMERR_ECC_POLLS 0x38

#define MEMERR_CAPS_ECC BIT(0)
#define MEMERR_CAPS_VERSION GENMASK(15, 8)

/* STATUS and IRQ_EN */
#define MEMERR_CE BIT(0)
#define MEMERR_UE BIT(1)
#define MEMERR_AXI_RD BIT(2)
#define MEMERR_AXI_WR BIT(3)
#define MEMERR_CE_ADDR_NEW BIT(4)
#define MEMERR_UE_ADDR_NEW BIT(5)
#define MEMERR_ALL GENMASK(5, 0)

/* AXI_ERR */
#define MEMERR_AXI_ERR_WRITE BIT(0)
#define MEMERR_AXI_ERR_RESP GENMASK(2, 1)
#define MEMERR_AXI_ERR_ID GENMASK(15, 8)

struct frost_memerr {
	struct device *dev;
	void __iomem *base;
	/* Counts already logged; only the interrupt handler and probe touch them. */
	u32 ce_logged;
	u32 rd_logged;
	u32 wr_logged;
};

static u32 memerr_read(struct frost_memerr *me, unsigned int offset)
{
	return readl(me->base + offset);
}

/* Log the reports that STATUS's bits, already cleared, announced. */
static void frost_memerr_log(struct frost_memerr *me, u32 status)
{
	u32 ce = memerr_read(me, MEMERR_CE_COUNT);
	u32 ue = memerr_read(me, MEMERR_UE_COUNT);
	u32 rd = memerr_read(me, MEMERR_AXI_RD_ERRS);
	u32 wr = memerr_read(me, MEMERR_AXI_WR_ERRS);
	u32 axi = memerr_read(me, MEMERR_AXI_ERR);
	u64 ue_addr = readq(me->base + MEMERR_UE_ADDR);

	if ((status & MEMERR_UE) && (status & MEMERR_UE_ADDR_NEW))
		dev_crit(me->dev, "uncorrectable memory error at %#llx (%u so far)\n",
			 ue_addr, ue);
	else if (status & MEMERR_UE)
		dev_crit(me->dev,
			 "uncorrectable memory error, address not captured (%u so far)\n",
			 ue);
	else if (status & MEMERR_UE_ADDR_NEW)
		dev_crit(me->dev, "uncorrectable memory error at %#llx\n", ue_addr);
	if (ce != me->ce_logged)
		dev_warn_ratelimited(me->dev, "%u corrected memory errors (%u so far)\n",
				     ce - me->ce_logged, ce);
	if (status & MEMERR_CE_ADDR_NEW)
		dev_warn_ratelimited(me->dev, "corrected memory error captured at %#llx\n",
				     readq(me->base + MEMERR_CE_ADDR));
	if (rd != me->rd_logged || wr != me->wr_logged)
		dev_err_ratelimited(me->dev,
				    "DDR error responses: %u reads, %u writes; the latest a %s, response %lu, id %lu\n",
				    rd - me->rd_logged, wr - me->wr_logged,
				    (axi & MEMERR_AXI_ERR_WRITE) ? "write" : "read",
				    FIELD_GET(MEMERR_AXI_ERR_RESP, axi),
				    FIELD_GET(MEMERR_AXI_ERR_ID, axi));
	me->ce_logged = ce;
	me->rd_logged = rd;
	me->wr_logged = wr;
}

static irqreturn_t frost_memerr_irq(int irq, void *data)
{
	struct frost_memerr *me = data;
	u32 status = memerr_read(me, MEMERR_STATUS) & MEMERR_ALL;

	if (!status)
		return IRQ_NONE;
	/* Clear before reading the counts: a report after this raises it again. */
	writel(status, me->base + MEMERR_STATUS);
	frost_memerr_log(me, status);
	return IRQ_HANDLED;
}

static ssize_t memerr_show32(struct device *dev, char *buf, unsigned int offset)
{
	struct frost_memerr *me = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%u\n", memerr_read(me, offset));
}

static ssize_t memerr_show64(struct device *dev, char *buf, unsigned int offset)
{
	struct frost_memerr *me = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%#llx\n", readq(me->base + offset));
}

#define MEMERR_ATTR(name, show, offset)                                          \
	static ssize_t name##_show(struct device *dev, struct device_attribute *attr, \
				   char *buf)                                         \
	{                                                                            \
		return show(dev, buf, offset);                                       \
	}                                                                            \
	static DEVICE_ATTR_RO(name)

MEMERR_ATTR(ce_count, memerr_show32, MEMERR_CE_COUNT);
MEMERR_ATTR(ue_count, memerr_show32, MEMERR_UE_COUNT);
MEMERR_ATTR(axi_read_errors, memerr_show32, MEMERR_AXI_RD_ERRS);
MEMERR_ATTR(axi_write_errors, memerr_show32, MEMERR_AXI_WR_ERRS);
MEMERR_ATTR(ecc_polls, memerr_show32, MEMERR_ECC_POLLS);
MEMERR_ATTR(ce_addr, memerr_show64, MEMERR_CE_ADDR);
MEMERR_ATTR(ue_addr, memerr_show64, MEMERR_UE_ADDR);

static ssize_t ecc_active_show(struct device *dev, struct device_attribute *attr,
			       char *buf)
{
	struct frost_memerr *me = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%u\n", !!(memerr_read(me, MEMERR_CAPS) & MEMERR_CAPS_ECC));
}
static DEVICE_ATTR_RO(ecc_active);

static struct attribute *frost_memerr_attrs[] = {
	&dev_attr_ecc_active.attr,
	&dev_attr_ecc_polls.attr,
	&dev_attr_ce_count.attr,
	&dev_attr_ue_count.attr,
	&dev_attr_axi_read_errors.attr,
	&dev_attr_axi_write_errors.attr,
	&dev_attr_ce_addr.attr,
	&dev_attr_ue_addr.attr,
	NULL,
};
ATTRIBUTE_GROUPS(frost_memerr);

static int frost_memerr_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct frost_memerr *me;
	u32 status;
	u32 caps;
	int irq;
	int err;

	me = devm_kzalloc(dev, sizeof(*me), GFP_KERNEL);
	if (!me)
		return -ENOMEM;
	me->dev = dev;
	me->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(me->base))
		return PTR_ERR(me->base);
	irq = platform_get_irq(pdev, 0);
	if (irq < 0)
		return irq;
	platform_set_drvdata(pdev, me);

	caps = memerr_read(me, MEMERR_CAPS);
	if (FIELD_GET(MEMERR_CAPS_VERSION, caps) != 1)
		return dev_err_probe(dev, -ENODEV, "unknown version, CAPS %#x\n", caps);

	/* Report what arrived between the unit's reset and now. */
	status = memerr_read(me, MEMERR_STATUS) & MEMERR_ALL;
	writel(status, me->base + MEMERR_STATUS);
	frost_memerr_log(me, status);
	err = devm_request_irq(dev, irq, frost_memerr_irq, 0, dev_name(dev), me);
	if (err)
		return dev_err_probe(dev, err, "requesting IRQ %d\n", irq);
	writel(MEMERR_ALL, me->base + MEMERR_IRQ_EN);
	dev_info(dev, "memory error reporting, ECC %s\n",
		 (caps & MEMERR_CAPS_ECC) ? "active" : "not reported");
	return 0;
}

static void frost_memerr_remove(struct platform_device *pdev)
{
	struct frost_memerr *me = platform_get_drvdata(pdev);

	writel(0, me->base + MEMERR_IRQ_EN);
}

static const struct of_device_id frost_memerr_of_match[] = {
	{ .compatible = "frost,memory-error" },
	{ }
};
MODULE_DEVICE_TABLE(of, frost_memerr_of_match);

static struct platform_driver frost_memerr_driver = {
	.probe = frost_memerr_probe,
	.remove = frost_memerr_remove,
	.driver = {
		.name = KBUILD_MODNAME,
		.of_match_table = frost_memerr_of_match,
		.dev_groups = frost_memerr_groups,
		.suppress_bind_attrs = true,
	},
};
module_platform_driver(frost_memerr_driver);

MODULE_DESCRIPTION("FROST memory error unit driver");
/* The DKMS package version: PACKAGE_VERSION in dkms.conf matches it */
MODULE_VERSION("1.0");
MODULE_LICENSE("Dual BSD/GPL");
