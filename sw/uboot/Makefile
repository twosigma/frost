#    Copyright 2026 John Goodacre
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

# Build U-Boot Proper (u-boot.bin) for FROST VCU118
UBOOT_SRC ?= /home/john_/build/u-boot-frost
CROSS_COMPILE ?= /home/john_/frost/linux/build-mmu/host/bin/riscv64-linux-
BUILD_DIR ?= $(CURDIR)/build

.PHONY: all clean

all: u-boot.bin

u-boot.bin:
	@if [ ! -d "$(UBOOT_SRC)" ]; then \
		echo "ERROR: U-Boot source tree not found at $(UBOOT_SRC)"; \
		exit 1; \
	fi
	@mkdir -p "$(BUILD_DIR)"
	@cp -f "$(CURDIR)/frost_net10g_uboot.c" "$(UBOOT_SRC)/drivers/net/frost_net10g.c"
	@cp -f "$(CURDIR)/frost_spi.c" "$(UBOOT_SRC)/drivers/spi/frost_spi.c"
	@if ! grep -q "CONFIG_FROST_NET10G" "$(UBOOT_SRC)/drivers/net/Makefile"; then \
		echo 'obj-$$(CONFIG_FROST_NET10G) += frost_net10g.o' >> "$(UBOOT_SRC)/drivers/net/Makefile"; \
	fi
	@if ! grep -q "FROST_NET10G" "$(UBOOT_SRC)/drivers/net/Kconfig"; then \
		printf '\nconfig FROST_NET10G\n\tbool "FROST 10G/1G Ethernet MAC support"\n\tdepends on DM_ETH\n\thelp\n\t  Support for FROST coherent-DMA Ethernet MAC.\n' >> "$(UBOOT_SRC)/drivers/net/Kconfig"; \
	fi
	@if ! grep -q "CONFIG_FROST_SPI" "$(UBOOT_SRC)/drivers/spi/Makefile"; then \
		echo 'obj-$$(CONFIG_FROST_SPI) += frost_spi.o' >> "$(UBOOT_SRC)/drivers/spi/Makefile"; \
	fi
	@if ! grep -q "FROST_SPI" "$(UBOOT_SRC)/drivers/spi/Kconfig"; then \
		printf '\nconfig FROST_SPI\n\tbool "FROST SPI controller support"\n\tdepends on DM_SPI\n\thelp\n\t  Support for FROST SPI flash controller.\n' >> "$(UBOOT_SRC)/drivers/spi/Kconfig"; \
	fi
	@cp -f "$(CURDIR)/configs/frost_vcu118_defconfig" "$(UBOOT_SRC)/configs/frost_vcu118_defconfig"
	$(MAKE) -C "$(UBOOT_SRC)" O="$(BUILD_DIR)" CROSS_COMPILE="$(CROSS_COMPILE)" frost_vcu118_defconfig
	$(MAKE) -C "$(UBOOT_SRC)" O="$(BUILD_DIR)" CROSS_COMPILE="$(CROSS_COMPILE)" -j$$(nproc)
	@cp -f "$(BUILD_DIR)/u-boot.bin" "$(CURDIR)/u-boot.bin"
	@cp -f "$(BUILD_DIR)/u-boot" "$(CURDIR)/u-boot.elf"
	@echo ">>> U-Boot build complete: $(CURDIR)/u-boot.bin"

clean:
	rm -rf "$(BUILD_DIR)" u-boot.bin u-boot.elf
