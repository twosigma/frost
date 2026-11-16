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

# OpenSBI fw_jump boots an S-mode payload using the FROST boot layout.
# linux/opensbi_build.py builds the firmware from linux/opensbi; link.ld
# keeps the payload below the DTB. MEM_CONFIG is ignored.
#
# The helper checks firmware inputs on every make and discards build/opensbi
# when the configuration, source, build options or toolchain changes.
# clean keeps matching firmware; distclean removes the cache.

FROST_ROOT := $(abspath $(CURDIR)/../../..)
BOARD_DIR  := $(FROST_ROOT)/linux/buildroot-external/board/frost
RISCV_PREFIX ?= riscv64-linux-
FPGA_CPU_CLK_FREQ ?= 322265625
OPENSBI_SMOKE_PAYLOAD_SRC ?= main.c
OPENSBI_SMOKE_PACKER ?= $(BOARD_DIR)/frost_boot_image.py

CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump

OPENSBI_OUT := $(CURDIR)/build/opensbi
FW_BIN      := $(OPENSBI_OUT)/platform/generic/firmware/fw_jump.bin

CFLAGS := -march=rv64imafdc_zicsr_zicntr_zifencei_zba_zbb_zbc_zbs_zicond_zbkb_zbkc_zihintpause \
          -mabi=lp64d -mcmodel=medany -O2 -Wall -Wextra -I../../lib/include \
          -nostdlib -nostartfiles -static -fno-pie -no-pie -fno-stack-protector -ffreestanding -fno-builtin \
          -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-strict-aliasing $(EXTRA_CFLAGS)

.PHONY: all clean distclean FORCE_OPENSBI FORCE_CONFIG

all: sw.mem sw64.mem sw.txt sw_ddr.mem sw_ddr.txt payload.S

FORCE_OPENSBI:

FORCE_CONFIG:

# Records the payload source, packer and extra C flags of the last build. The
# file is written verbatim by make (the shell never sees the settings) and
# replaced only when its content changes, so the payload and packed
# images are rebuilt exactly when one of them changes between invocations.
CONFIG_STAMP := .config.stamp
CONFIG_TEXT  := payload=$(OPENSBI_SMOKE_PAYLOAD_SRC) packer=$(OPENSBI_SMOKE_PACKER) cflags=$(EXTRA_CFLAGS)

$(CONFIG_STAMP): FORCE_CONFIG
	$(file >$@.tmp,$(CONFIG_TEXT))
	@if cmp -s $@.tmp $@; then rm -f $@.tmp; else mv -f $@.tmp $@; fi

$(FW_BIN): FORCE_OPENSBI
	python3 $(FROST_ROOT)/linux/opensbi_build.py --out $(OPENSBI_OUT)

payload.elf: start.S $(OPENSBI_SMOKE_PAYLOAD_SRC) link.ld ../../lib/include/aplic.h $(CONFIG_STAMP)
	$(CC) $(CFLAGS) -T link.ld -Wl,--gc-sections -o $@ start.S $(OPENSBI_SMOKE_PAYLOAD_SRC)

payload.bin: payload.elf
	$(OBJCOPY) -O binary $< $@

payload.S: payload.elf
	$(OBJDUMP) -d $< > $@

# One packer run writes every image. Group the outputs so parallel make cannot
# launch competing packers that overwrite the shared DTS/DTB and shim files.
sw.mem sw.txt sw_ddr.mem sw_ddr.txt &: payload.bin $(FW_BIN) $(OPENSBI_SMOKE_PACKER) $(BOARD_DIR)/frost_boot_image.py $(CONFIG_STAMP)
	FPGA_CPU_CLK_FREQ=$(FPGA_CPU_CLK_FREQ) python3 $(OPENSBI_SMOKE_PACKER) \
	    --firmware $(FW_BIN) --payload payload.bin --out . --cross $(RISCV_PREFIX) \
	    --bootargs "" --model "FROST OpenSBI smoke"

sw64.mem: sw.mem ../../common/make_dword_mem.py
	python3 ../../common/make_dword_mem.py '$<' '$@'

clean:
	rm -f payload.elf payload.bin payload.S sw.mem sw64.mem sw.txt sw_ddr.mem sw_ddr.txt \
	      frost.dts frost.dtb frost_boot_shim.S shim.elf shim.bin $(CONFIG_STAMP) $(CONFIG_STAMP).tmp

distclean: clean
	rm -rf build
