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

# OpenSBI smoke test: the real fw_jump firmware (linux/opensbi, built by
# linux/opensbi_build.py) boots a bare S-mode payload through the FROST boot
# layout (frost_boot_image.py: firmware +0, payload +2 MiB, DTB +16 MiB). The
# outputs are the standard sw.{mem,txt} (low-BRAM shim), sw64.mem, and
# sw_ddr.{mem,txt} images that cocotb and the JTAG loader consume.
#
# The firmware build is cached under build/opensbi (make clean keeps it;
# distclean removes it) so a board reload after a container build does not
# need the Linux-targeted toolchain on the host. MEM_CONFIG is ignored: the
# layout is fixed by the firmware.

FROST_ROOT := $(abspath $(CURDIR)/../../..)
BOARD_DIR  := $(FROST_ROOT)/linux/buildroot-external/board/frost
RISCV_PREFIX ?= riscv-none-elf-
FPGA_CPU_CLK_FREQ ?= 300000000

CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump

OPENSBI_OUT := $(CURDIR)/build/opensbi
FW_BIN      := $(OPENSBI_OUT)/platform/generic/firmware/fw_jump.bin

CFLAGS := -march=rv64imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause \
          -mabi=lp64d -mcmodel=medany -O2 -Wall -Wextra \
          -nostdlib -nostartfiles -ffreestanding -fno-builtin \
          -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-strict-aliasing

.PHONY: all clean distclean

all: sw.mem sw64.mem sw.txt sw_ddr.mem sw_ddr.txt payload.S

$(FW_BIN):
	python3 $(FROST_ROOT)/linux/opensbi_build.py --out $(OPENSBI_OUT)

payload.elf: start.S main.c link.ld
	$(CC) $(CFLAGS) -T link.ld -Wl,--gc-sections -o $@ start.S main.c

payload.bin: payload.elf
	$(OBJCOPY) -O binary $< $@

payload.S: payload.elf
	$(OBJDUMP) -d $< > $@

# One packer run writes every image; sw.mem is the representative target.
sw.mem sw.txt sw_ddr.mem sw_ddr.txt: payload.bin $(FW_BIN) $(BOARD_DIR)/frost_boot_image.py
	FPGA_CPU_CLK_FREQ=$(FPGA_CPU_CLK_FREQ) python3 $(BOARD_DIR)/frost_boot_image.py \
	    --firmware $(FW_BIN) --payload payload.bin --out . --cross $(RISCV_PREFIX) \
	    --bootargs "" --model "FROST OpenSBI smoke"

sw64.mem: sw.mem ../../common/make_dword_mem.py
	python3 ../../common/make_dword_mem.py '$<' '$@'

clean:
	rm -f payload.elf payload.bin payload.S sw.mem sw64.mem sw.txt sw_ddr.mem sw_ddr.txt \
	      frost.dts frost.dtb frost_boot_shim.S shim.elf shim.bin

distclean: clean
	rm -rf build
