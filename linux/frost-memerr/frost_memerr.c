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
 * handled, and exposes counters as read-only sysfs attributes. A new CE
 * address queues a line scrub in process context. A background patrol reads
 * RAM to find errors in idle data. A read that ends in an error response
 * still delivers its data; the kernel is not stopped.
 *
 * Registers are 32 bits, read with readl() and written with writel() at
 * 4-aligned offsets; the two 64-bit address registers are read with readq().
 * The register bus writes only the upper register of a 64-bit store's dword.
 */

#include <linux/atomic.h>
#include <linux/bitfield.h>
#include <linux/bits.h>
#include <linux/debugfs.h>
#include <linux/device.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/ioport.h>
#include <linux/jiffies.h>
#include <linux/kfifo.h>
#include <linux/math64.h>
#include <linux/mm.h>
#include <linux/mmzone.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>
#include <linux/vmalloc.h>
#include <linux/workqueue.h>

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

#define MEMERR_LINE_BYTES 64
#define MEMERR_PATROL_BATCH_MAX 4096

static unsigned int patrol_seconds = 86400;
module_param(patrol_seconds, uint, 0444);
MODULE_PARM_DESC(patrol_seconds, "Seconds per RAM patrol pass (0 disables patrol)");

struct frost_memerr {
	struct device *dev;
	void __iomem *base;
	phys_addr_t reg_addr;
	int irq;
	struct dentry *debugfs;
	struct work_struct scrub_work;
	DECLARE_KFIFO(scrub_queue, u64, 64);
	spinlock_t scrub_lock;
	atomic64_t scrubbed_lines;
	atomic64_t scrub_skipped;
	atomic64_t patrol_lines;
	atomic64_t patrol_passes;
	struct delayed_work patrol_work;
	u64 ram_lines;
	u64 patrol_cursor;
	u64 patrol_visited;
	u64 patrol_start;
	unsigned int patrol_batch;
	/* Counts already logged; only the interrupt handler and probe touch them. */
	u32 ce_logged;
	u32 rd_logged;
	u32 wr_logged;
};

static u32 memerr_read(struct frost_memerr *me, unsigned int offset)
{
	return readl(me->base + offset);
}

struct memerr_ram_check {
	u64 addr;
	bool found;
};

static int memerr_check_ram(struct resource *res, void *arg)
{
	struct memerr_ram_check *check = arg;

	check->found = res->start <= check->addr &&
		res->end >= check->addr + MEMERR_LINE_BYTES - 1;
	return check->found;
}

static int frost_memerr_scrub_line(struct frost_memerr *me, u64 addr)
{
	struct memerr_ram_check check = {
		.addr = round_down(addr, MEMERR_LINE_BYTES),
	};
	struct page *page;
	atomic64_t *words;
	void *mapping;
	int err = -ENXIO;
	int i;

	/* A valid PFN alone can include holes in a sparse memory section. */
	walk_iomem_res_desc(IORES_DESC_NONE, IORESOURCE_SYSTEM_RAM | IORESOURCE_BUSY,
			    check.addr, check.addr + MEMERR_LINE_BYTES - 1,
			    &check, memerr_check_ram);
	if (!check.found)
		goto skipped;
	page = pfn_to_online_page(PHYS_PFN(check.addr));
	if (!page)
		goto skipped;

	/* Text and rodata can have read-only aliases in the linear map. */
	mapping = vmap(&page, 1, VM_MAP, PAGE_KERNEL);
	if (!mapping) {
		err = -ENOMEM;
		goto skipped;
	}
	words = mapping + offset_in_page(check.addr);
	/* DMA admission waits for each AMO. A load/store pair could lose a write. */
	for (i = 0; i < MEMERR_LINE_BYTES / sizeof(*words); i++)
		atomic64_add(0, &words[i]);
	vunmap(mapping);
	atomic64_inc(&me->scrubbed_lines);
	return 0;

skipped:
	atomic64_inc(&me->scrub_skipped);
	return err;
}

static void frost_memerr_scrub_work(struct work_struct *work)
{
	struct frost_memerr *me = container_of(work, struct frost_memerr, scrub_work);
	u64 addr;

	while (kfifo_out_spinlocked(&me->scrub_queue, &addr, 1, &me->scrub_lock)) {
		frost_memerr_scrub_line(me, addr);
		cond_resched();
	}
}

static void frost_memerr_queue_scrub(struct frost_memerr *me, u64 addr)
{
	if (!kfifo_in_spinlocked(&me->scrub_queue, &addr, 1, &me->scrub_lock)) {
		atomic64_inc(&me->scrub_skipped);
		return;
	}
	schedule_work(&me->scrub_work);
}

static int memerr_count_ram(struct resource *res, void *arg)
{
	struct frost_memerr *me = arg;
	u64 start = ALIGN(res->start, MEMERR_LINE_BYTES);
	u64 end = round_down(res->end + 1, MEMERR_LINE_BYTES);

	if (end > start)
		me->ram_lines += (end - start) / MEMERR_LINE_BYTES;
	return 0;
}

struct memerr_patrol {
	struct frost_memerr *me;
	unsigned int left;
	unsigned int read;
	unsigned long deadline;
};

static int memerr_read_ram(struct resource *res, void *arg)
{
	struct memerr_patrol *patrol = arg;
	struct frost_memerr *me = patrol->me;
	u64 addr = ALIGN(res->start, MEMERR_LINE_BYTES);
	u64 end = round_down(res->end + 1, MEMERR_LINE_BYTES);
	u64 word;

	while (addr < end) {
		u64 page_end = min(end, (addr | (PAGE_SIZE - 1)) + 1);
		bool online = pfn_to_online_page(PHYS_PFN(addr));

		/* The nofault read also tolerates pages absent from the linear map. */
		do {
			if (online && !copy_from_kernel_nofault(&word, __va(addr),
							      sizeof(word)))
				patrol->read++;
			addr += MEMERR_LINE_BYTES;
			me->patrol_cursor = addr;
			me->patrol_visited++;
			patrol->left--;
		} while (addr < page_end && patrol->left);
		cond_resched();
		if (!patrol->left || time_after_eq(jiffies, patrol->deadline))
			return 1;
	}
	return 0;
}

static void frost_memerr_patrol_work(struct work_struct *work)
{
	struct frost_memerr *me = container_of(to_delayed_work(work),
					     struct frost_memerr, patrol_work);
	struct memerr_patrol patrol = {
		.me = me,
		.left = me->patrol_batch,
		.deadline = jiffies + msecs_to_jiffies(2),
	};
	u64 period = (u64)patrol_seconds * HZ;
	u64 now, due, delay;
	int ret;

	ret = walk_iomem_res_desc(IORES_DESC_NONE,
				 IORESOURCE_SYSTEM_RAM | IORESOURCE_BUSY,
				 me->patrol_cursor, U64_MAX, &patrol, memerr_read_ram);
	atomic64_add(patrol.read, &me->patrol_lines);
	now = get_jiffies_64();
	/* -EINVAL also means there is no RAM left after the last batch. */
	if (ret <= 0) {
		atomic64_inc(&me->patrol_passes);
		me->patrol_cursor = 0;
		me->patrol_visited = 0;
		me->patrol_start = max(me->patrol_start + period, now);
	}
	/* Pace by the pass's start, so time spent reading does not add drift. */
	due = me->patrol_start + mul_u64_u64_div_u64(me->patrol_visited,
						   period, me->ram_lines);
	delay = due > now ? min_t(u64, due - now, MAX_JIFFY_OFFSET) : 1;
	schedule_delayed_work(&me->patrol_work, delay);
}

static int memerr_scrub_set(void *data, u64 addr)
{
	return frost_memerr_scrub_line(data, addr);
}
DEFINE_DEBUGFS_ATTRIBUTE(memerr_scrub_fops, NULL, memerr_scrub_set, "%llu\n");

static int memerr_selftest_show(struct seq_file *s, void *unused)
{
	struct frost_memerr *me = s->private;
	struct page *page;
	u64 *words;
	unsigned int i;
	bool pass = false;

	page = alloc_page(GFP_KERNEL);
	if (!page)
		goto result;
	words = page_address(page);
	for (i = 0; i < PAGE_SIZE / sizeof(*words); i++)
		words[i] = 0x5a39c6e187d24bf0ULL ^ i;
	for (i = 0; i < PAGE_SIZE; i += MEMERR_LINE_BYTES) {
		if (frost_memerr_scrub_line(me, page_to_phys(page) + i))
			goto free;
		cond_resched();
	}
	for (i = 0; i < PAGE_SIZE / sizeof(*words); i++) {
		if (READ_ONCE(words[i]) != (0x5a39c6e187d24bf0ULL ^ i))
			goto free;
	}
	pass = frost_memerr_scrub_line(me, me->reg_addr) == -ENXIO;
free:
	__free_page(page);
result:
	seq_printf(s, "FROST_MEMERR_SELFTEST_%s\n", pass ? "PASS" : "FAIL");
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(memerr_selftest);

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
	if (status & MEMERR_CE_ADDR_NEW) {
		u64 addr = readq(me->base + MEMERR_CE_ADDR);

		dev_warn_ratelimited(me->dev, "corrected memory error captured at %#llx\n",
				     addr);
		frost_memerr_queue_scrub(me, addr);
	}
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

#define MEMERR_COUNTER_ATTR(name) \
	static ssize_t name##_show(struct device *dev, struct device_attribute *attr, \
				  char *buf) \
	{ \
		struct frost_memerr *me = dev_get_drvdata(dev); \
		\
		return sysfs_emit(buf, "%lld\n", atomic64_read(&me->name)); \
	} \
	static DEVICE_ATTR_RO(name)

MEMERR_COUNTER_ATTR(scrubbed_lines);
MEMERR_COUNTER_ATTR(scrub_skipped);
MEMERR_COUNTER_ATTR(patrol_lines);
MEMERR_COUNTER_ATTR(patrol_passes);

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
	&dev_attr_scrubbed_lines.attr,
	&dev_attr_scrub_skipped.attr,
	&dev_attr_patrol_lines.attr,
	&dev_attr_patrol_passes.attr,
	NULL,
};
ATTRIBUTE_GROUPS(frost_memerr);

static void frost_memerr_stop(void *data)
{
	struct frost_memerr *me = data;

	writel(0, me->base + MEMERR_IRQ_EN);
	synchronize_irq(me->irq);
	debugfs_remove_recursive(me->debugfs);
	cancel_delayed_work_sync(&me->patrol_work);
	cancel_work_sync(&me->scrub_work);
}

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
	INIT_KFIFO(me->scrub_queue);
	spin_lock_init(&me->scrub_lock);
	INIT_WORK(&me->scrub_work, frost_memerr_scrub_work);
	INIT_DELAYED_WORK(&me->patrol_work, frost_memerr_patrol_work);
	me->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(me->base))
		return PTR_ERR(me->base);
	irq = platform_get_irq(pdev, 0);
	if (irq < 0)
		return irq;
	me->irq = irq;
	me->reg_addr = platform_get_resource(pdev, IORESOURCE_MEM, 0)->start;
	platform_set_drvdata(pdev, me);

	caps = memerr_read(me, MEMERR_CAPS);
	if (FIELD_GET(MEMERR_CAPS_VERSION, caps) != 1)
		return dev_err_probe(dev, -ENODEV, "unknown version, CAPS %#x\n", caps);

	writel(0, me->base + MEMERR_IRQ_EN);
	err = devm_request_irq(dev, irq, frost_memerr_irq, 0, dev_name(dev), me);
	if (err)
		return dev_err_probe(dev, err, "requesting IRQ %d\n", irq);
	/* Stop all users of the mapping before devres releases the IRQ and MMIO. */
	err = devm_add_action_or_reset(dev, frost_memerr_stop, me);
	if (err)
		return err;
	/* Report what arrived between the unit's reset and now. */
	status = memerr_read(me, MEMERR_STATUS) & MEMERR_ALL;
	writel(status, me->base + MEMERR_STATUS);
	frost_memerr_log(me, status);
	writel(MEMERR_ALL, me->base + MEMERR_IRQ_EN);
	me->debugfs = debugfs_create_dir(KBUILD_MODNAME, NULL);
	debugfs_create_file_unsafe("scrub", 0200, me->debugfs, me, &memerr_scrub_fops);
	debugfs_create_file("selftest", 0400, me->debugfs, me, &memerr_selftest_fops);
	if (patrol_seconds) {
		walk_iomem_res_desc(IORES_DESC_NONE,
				    IORESOURCE_SYSTEM_RAM | IORESOURCE_BUSY,
				    0, U64_MAX, me, memerr_count_ram);
		if (me->ram_lines) {
			me->patrol_batch = clamp_t(u64,
				div64_u64(me->ram_lines, (u64)patrol_seconds * 10),
				1, MEMERR_PATROL_BATCH_MAX);
			me->patrol_start = get_jiffies_64();
			schedule_delayed_work(&me->patrol_work, 1);
		}
	}
	dev_info(dev, "memory error reporting, ECC %s\n",
		 (caps & MEMERR_CAPS_ECC) ? "active" : "not reported");
	return 0;
}

static const struct of_device_id frost_memerr_of_match[] = {
	{ .compatible = "frost,memory-error" },
	{ }
};
MODULE_DEVICE_TABLE(of, frost_memerr_of_match);

static struct platform_driver frost_memerr_driver = {
	.probe = frost_memerr_probe,
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
MODULE_VERSION("1.1");
MODULE_LICENSE("Dual BSD/GPL");
