# SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
#
# Makefile for the FROST network device drivers.
#
# In the kernel tree (drivers/net/ethernet/frost/) Kconfig selects the
# driver. An external module build, make -C <kernel build dir> M=<this
# directory> as DKMS runs it, always builds it as a module.
#

ifneq ($(KBUILD_EXTMOD),)
CONFIG_FROST_NET10G := m
endif

obj-$(CONFIG_FROST_NET10G) += frost_net10g.o
