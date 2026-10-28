#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

"""Compile the U-Boot drivers against a small device-model and MMIO fixture."""

from pathlib import Path
import subprocess

from test_fpga_managed_flows import ROOT

STUB = r"""
#ifndef FROST_UBOOT_TEST_H
#define FROST_UBOOT_TEST_H
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef unsigned int uint;
typedef unsigned char uchar;
typedef uintptr_t fdt_addr_t;
#define __iomem
#define BIT(n) (1u << (n))
#define FDT_ADDR_T_NONE ((uintptr_t)-1)
#define UCLASS_ETH 1
#define UCLASS_SPI 2
#define SPI_XFER_BEGIN 1
#define SPI_XFER_END 2
#define max_t(type,a,b) ((type)(a) > (type)(b) ? (type)(a) : (type)(b))
#define mb() __atomic_thread_fence(__ATOMIC_SEQ_CST)
struct udevice { void *priv; void *plat; struct udevice *parent; const char *name; uintptr_t addr; };
struct eth_pdata { u8 enetaddr[6]; };
struct eth_ops {
 int (*start)(struct udevice *);
 int (*send)(struct udevice *,void *,int);
 int (*recv)(struct udevice *,int,uchar **);
 int (*free_pkt)(struct udevice *,uchar *,int);
 void (*stop)(struct udevice *);
 int (*write_hwaddr)(struct udevice *);
};
struct dm_spi_ops {
 int (*claim_bus)(struct udevice *);
 int (*release_bus)(struct udevice *);
 int (*xfer)(struct udevice *,unsigned,const void *,void *,unsigned long);
 int (*set_speed)(struct udevice *,uint);
 int (*set_mode)(struct udevice *,uint);
};
struct udevice_id { const char *compatible; };
struct driver { const char *name; int id; const struct udevice_id *of_match;
 int (*probe)(struct udevice *); int (*remove)(struct udevice *);
 int (*of_to_plat)(struct udevice *); const void *ops; size_t priv_auto,plat_auto; };
#define U_BOOT_DRIVER(name) struct driver name
static inline void *dev_get_priv(struct udevice *d) {return d->priv;}
static inline void *dev_get_plat(struct udevice *d) {return d->plat;}
static inline uintptr_t dev_read_addr(struct udevice *d) {return d->addr;}
static inline u32 dev_read_u32_default(struct udevice *d,const char *n,u32 v) {return 200000000;}
static unsigned allocations, frees, fail_allocation;
static void *test_memalign(size_t alignment,size_t size) {
 return ++allocations == fail_allocation ? NULL : aligned_alloc(alignment,size);
}
static void test_free(void *p) {if (p) {frees++; free(p);}}
#define memalign test_memalign
#define free test_free
static unsigned writes;
static u32 written[100];
static inline u32 readl(const void *p) {return *(const volatile u32 *)p;}
static inline void writel(u32 v,void *p) {written[writes++ % 100]=v; *(volatile u32 *)p=v;}
#define readl_poll_timeout(addr,val,condition,timeout) ({val=readl(addr); (condition)?0:-ETIMEDOUT;})
#endif
"""


def compile_and_run(tmp_path: Path, driver: str, body: str) -> None:
    """Execute the production driver with controlled MMIO and allocation results."""
    for header in (
        "dm.h",
        "net.h",
        "malloc.h",
        "spi.h",
        "asm/io.h",
        "asm/barrier.h",
        "linux/delay.h",
        "linux/iopoll.h",
        "linux/kernel.h",
    ):
        path = tmp_path / header
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#include "fixture.h"\n')
    (tmp_path / "fixture.h").write_text(STUB)
    source = tmp_path / "test.c"
    source.write_text(f'#include "{ROOT / "sw/uboot" / driver}"\n' + body)
    binary = tmp_path / "test"
    subprocess.run(
        [
            "cc",
            "-std=gnu11",
            "-I",
            str(tmp_path),
            "-Werror=implicit-function-declaration",
            str(source),
            "-o",
            str(binary),
        ],
        check=True,
    )
    subprocess.run([str(binary)], check=True)


def test_rx_error_recycles_and_allocation_failure_cleans_up(tmp_path: Path) -> None:
    """A bad completion must not strand the receive ring; failed probes free memory."""
    compile_and_run(
        tmp_path,
        "frost_net10g_uboot.c",
        r"""
int main(void) {
 u32 regs[128]={0}; struct frost_desc ring[16]={0};
 struct frost_net10g_priv priv={.base=regs,.rx_ring=ring,.rx_tail=15};
 struct udevice dev={.priv=&priv,.addr=(uintptr_t)regs}; uchar *packet;
 u32 errors[]={NET10G_DESC_ERR,NET10G_DESC_ABORT,NET10G_DESC_TRUNC};
 for (unsigned i=0;i<3;i++) {
  ring[i].word0=0x81000000+i*2048;
  ring[i].word2=NET10G_DESC_DD|errors[i]|64;
  assert(frost_net10g_recv(&dev,0,&packet)==-EAGAIN);
  assert(priv.rx_clean==i+1);
  assert(ring[(i+15)&15].word0==0x81000000+i*2048);
  assert(regs[NET10G_RX_TAIL/4]==((i+16)&15));
 }
 ring[3].word0=0x82000000; ring[3].word2=NET10G_DESC_DD|64;
 assert(frost_net10g_recv(&dev,0,&packet)==64);
 assert((uintptr_t)packet==0x82000000);
 assert(priv.rx_clean==3);
 for (unsigned i=1;i<=4;i++) {
  allocations=frees=0; fail_allocation=i; regs[0]=NET10G_ID_VALUE;
  assert(frost_net10g_probe(&dev)==-ENOMEM);
  assert(frees==3);
 }
 return 0;
}
""",
    )


def test_spi_select_speed_mode_and_timeout(tmp_path: Path) -> None:
    """CS follows transaction flags, rates are bounded, and failures deselect flash."""
    compile_and_run(
        tmp_path,
        "frost_spi.c",
        r"""
int main(void) {
 u32 regs[8]={0}; struct frost_spi_priv priv={.regs=regs,.clk_div=6,.clock_hz=200000000};
 struct udevice bus={.priv=&priv}; struct udevice dev={.parent=&bus}; u8 tx=0x9f;
 assert(frost_spi_claim_bus(&dev)==0 && (regs[0]&1));
 assert(frost_spi_set_mode(&bus,0)==0);
 assert(frost_spi_set_mode(&bus,1)==-EINVAL);
 assert(frost_spi_set_speed(&bus,0)==-EINVAL);
 assert(frost_spi_set_speed(&bus,1000)==-EINVAL);
 assert(frost_spi_set_speed(&bus,10000000)==0 && priv.clk_div==10);
 assert(frost_spi_set_speed(&bus,20000000)==0 && priv.clk_div==6);
 assert(frost_spi_xfer(&dev,8,&tx,NULL,SPI_XFER_BEGIN)==0 && !(regs[0]&1));
 assert(frost_spi_xfer(&dev,0,NULL,NULL,SPI_XFER_END)==0 && (regs[0]&1));
 regs[1]=SYS_STATUS_SPI_BUSY;
 assert(frost_spi_xfer(&dev,8,&tx,NULL,SPI_XFER_BEGIN)==-ETIMEDOUT && (regs[0]&1));
 assert(frost_spi_xfer(&dev,7,&tx,NULL,0)==-EINVAL);
 return 0;
}
""",
    )


def test_documented_boot_chain_has_required_support() -> None:
    """Conditional transfers and a raw initramfs require both U-Boot options."""
    guide = (ROOT / "boards/vcu118/README.md").read_text()
    config = (ROOT / "sw/uboot/configs/frost_vcu118_defconfig").read_text()
    assert "dhcp && tftpboot" in guide
    assert "rootfs.cpio && booti" in guide
    assert "CONFIG_HUSH_PARSER=y" in config.splitlines()
    assert "CONFIG_SUPPORT_RAW_INITRD=y" in config.splitlines()


def test_unknown_or_changed_kconfig_is_rejected(tmp_path: Path) -> None:
    """Obsolete and dependency-disabled selections fail before compilation."""
    from test_fpga_managed_flows import load_module

    import pytest

    checker = load_module("uboot_config_check", "sw/uboot/check_config.py")
    requested = tmp_path / "requested"
    generated = tmp_path / "generated"
    requested.write_text("CONFIG_FLASH=y\nCONFIG_VALUE=42\n# CONFIG_BAR is not set\n")
    for actual in (
        "CONFIG_VALUE=42\n",
        "CONFIG_FLASH=y\nCONFIG_VALUE=43\n",
        "CONFIG_FLASH=y\nCONFIG_VALUE=42\nCONFIG_BAR=y\n",
    ):
        generated.write_text(actual)
        with pytest.raises(ValueError, match="did not apply"):
            checker.validate_config(requested, generated)
    generated.write_text(requested.read_text())
    checker.validate_config(requested, generated)
    generated.write_text("CONFIG_FLASH=y\nCONFIG_VALUE=42\n")
    checker.validate_config(requested, generated)


def test_firmware_forwards_the_compiler(tmp_path: Path) -> None:
    """The aggregate build uses one prefix for U-Boot, ROM, FSBL and OpenSBI."""
    import os

    work = tmp_path / "sw/uboot"
    work.mkdir(parents=True)
    log = tmp_path / "calls"
    capture = tmp_path / "capture"
    capture.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{log}"\n')
    capture.chmod(0o755)
    (tmp_path / "python3").symlink_to(capture)
    subprocess.run(
        [
            "make",
            "-f",
            str(ROOT / "sw/uboot/Makefile"),
            "firmware",
            "-o",
            "all",
            "-o",
            "dtb",
            "CROSS_COMPILE=selected-",
            "MAKE=" + str(capture),
        ],
        cwd=work,
        check=True,
        env={**os.environ, "PATH": str(tmp_path) + os.pathsep + os.environ["PATH"]},
    )
    calls = log.read_text().splitlines()
    assert calls[0] == "-C ../apps/bootrom RISCV_PREFIX=selected-"
    assert calls[1] == "-C ../apps/fsbl RISCV_PREFIX=selected-"
    assert "--cross selected-" in calls[2]
