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

# FROST BR2_EXTERNAL makefile.
#
# Standard BR2_EXTERNAL package hook. frost-stress runs from the overlay
# inittab and prints FROST_USERSPACE_STRESS_PASS/_FAIL for CI.
include $(sort $(wildcard $(BR2_EXTERNAL_FROST_PATH)/package/*/*.mk))

# The frost_net10g NIC driver's one source is linux/frost-net10g, which is also
# its DKMS package. board/frost/patches/linux adds drivers/net/ethernet/frost/
# to the kernel's Kconfig and Makefile, and these hooks install the driver's
# files there, rewriting only files whose contents changed, so an unchanged
# driver is not recompiled:
# - after patching, all three, before the kernel configuration reads Kconfig.
#   A changed Kconfig, like a changed patch, needs linux-dirclean.
# - before every kernel build, the source and the Makefile, so
#   linux-rebuild picks up an edited driver.
# legal-info saves them, and the driver's README, next to the kernel's
# tarball and patches.
FROST_NET10G_SRC_DIR = $(BR2_EXTERNAL_FROST_PATH)/../frost-net10g
FROST_NET10G_KERNEL_DIR = $(LINUX_DIR)/drivers/net/ethernet/frost
FROST_NET10G_KERNEL_FILES = Kconfig Makefile frost_net10g.c
FROST_NET10G_BUILD_FILES = Makefile frost_net10g.c

# $(1): the files to install
define FROST_NET10G_INSTALL
	$(INSTALL) -d $(FROST_NET10G_KERNEL_DIR)
	for f in $(1); do \
		cmp -s $(FROST_NET10G_SRC_DIR)/$$f $(FROST_NET10G_KERNEL_DIR)/$$f || \
		$(INSTALL) -m 0644 $(FROST_NET10G_SRC_DIR)/$$f \
			$(FROST_NET10G_KERNEL_DIR)/$$f || exit 1; \
	done
endef

define FROST_NET10G_INSTALL_KERNEL_SOURCES
	$(call FROST_NET10G_INSTALL,$(FROST_NET10G_KERNEL_FILES))
endef
LINUX_POST_PATCH_HOOKS += FROST_NET10G_INSTALL_KERNEL_SOURCES

define FROST_NET10G_REFRESH_BUILD_SOURCES
	$(call FROST_NET10G_INSTALL,$(FROST_NET10G_BUILD_FILES))
endef
LINUX_PRE_BUILD_HOOKS += FROST_NET10G_REFRESH_BUILD_SOURCES

define FROST_NET10G_LEGAL_INFO
	$(INSTALL) -d $(LINUX_REDIST_SOURCES_DIR)/frost-net10g
	$(INSTALL) -m 0644 \
		$(addprefix $(FROST_NET10G_SRC_DIR)/,$(FROST_NET10G_KERNEL_FILES) README.md) \
		$(LINUX_REDIST_SOURCES_DIR)/frost-net10g
endef
LINUX_POST_LEGAL_INFO_HOOKS += FROST_NET10G_LEGAL_INFO

# perf (linux-tools) in the MMU lane: perf 6.x builds BPF skeletons whenever
# it finds a clang, which the frost image has for clang-tidy; that build
# compiles BPF programs against the host's kernel headers and fails there
# (asm/ioctl.h is under the multiarch directory clang's BPF target does not
# search). Buildroot has no knob for it, and external.mk is included after
# the package makefiles, so append perf's own override here. FROST needs no
# BPF-backed perf features.
PERF_MAKE_FLAGS += BUILD_BPF_SKEL=0
