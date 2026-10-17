# SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
#
# Makefile for the FROST memory error unit driver.
#
# In the kernel tree (drivers/edac/ or drivers/soc/frost/) Kconfig selects the
# driver. An external module build, make -C <kernel build dir> M=<this
# directory> as DKMS runs it, always builds it as a module.
#

ifneq ($(KBUILD_EXTMOD),)
CONFIG_FROST_MEMERR := m
endif

obj-$(CONFIG_FROST_MEMERR) += frost_memerr.o
