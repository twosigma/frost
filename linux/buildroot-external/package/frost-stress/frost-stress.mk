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

################################################################################
#
# frost-stress: FROST userspace boot stress payload (see src/frost_stress.c)
#
################################################################################

FROST_STRESS_VERSION = 1.0
FROST_STRESS_SITE = $(BR2_EXTERNAL_FROST_PATH)/package/frost-stress/src
FROST_STRESS_SITE_METHOD = local
FROST_STRESS_LICENSE = Apache-2.0
FROST_STRESS_LICENSE_FILES =

# The 4 KiB elf2flt default is too small for printf plus a signal frame.
# Buildroot expands this to -Wl,-elf2flt="-r -s16384" and adds -fPIC through
# TARGET_CFLAGS. Without -r and -fPIC, the unrelocated GOT SIGSEGVs on the
# first global store.
FROST_STRESS_FLAT_STACKSIZE = 16384

# The MMU lane builds the fork/mmap/perf_event_open edition of the payload;
# the no-MMU lane keeps the vfork/bFLT/rdcycle one (see frost_stress.c).
FROST_STRESS_CFLAGS = $(if $(BR2_USE_MMU),-DFROST_STRESS_MMU=1)

define FROST_STRESS_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(FROST_STRESS_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(@D)/frost_stress $(@D)/frost_stress.c
endef

define FROST_STRESS_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/frost_stress \
		$(TARGET_DIR)/usr/bin/frost_stress
endef

$(eval $(generic-package))
