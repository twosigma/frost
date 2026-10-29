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

# U-Boot v2026.10, built with the FROST drivers in a private source tree.
UBOOT_REV := 5508406582f6f7120dce0c4b3059819a41788db2
CROSS_COMPILE ?= riscv64-linux-
BUILD_DIR ?= $(CURDIR)/build
SOURCE_DIR := $(BUILD_DIR)/source
OUTPUT_DIR := $(BUILD_DIR)/out
JOBS ?= 8

.PHONY: all clean
all: u-boot.bin

$(SOURCE_DIR)/.frost-source:
	mkdir -p "$(SOURCE_DIR)"
	git -C "$(SOURCE_DIR)" init
	git -C "$(SOURCE_DIR)" fetch --depth 1 https://github.com/u-boot/u-boot.git $(UBOOT_REV)
	git -C "$(SOURCE_DIR)" checkout --detach $(UBOOT_REV)
	touch "$@"

u-boot.bin: $(SOURCE_DIR)/.frost-source frost_net10g_uboot.c frost_spi.c configs/frost_vcu118_defconfig Makefile check_config.py
	cp frost_net10g_uboot.c "$(SOURCE_DIR)/drivers/net/frost_net10g.c"
	cp frost_spi.c "$(SOURCE_DIR)/drivers/spi/frost_spi.c"
	cp configs/frost_vcu118_defconfig "$(SOURCE_DIR)/configs/"
	@if ! grep -q CONFIG_FROST_NET10G "$(SOURCE_DIR)/drivers/net/Makefile"; then \
		printf '\nobj-$$(CONFIG_FROST_NET10G) += frost_net10g.o\n' >> "$(SOURCE_DIR)/drivers/net/Makefile"; \
		printf '\nconfig FROST_NET10G\n\tbool "FROST Ethernet MAC"\n\tdepends on DM_ETH\n' >> "$(SOURCE_DIR)/drivers/net/Kconfig"; \
	fi
	@if ! grep -q CONFIG_FROST_SPI "$(SOURCE_DIR)/drivers/spi/Makefile"; then \
		printf '\nobj-$$(CONFIG_FROST_SPI) += frost_spi.o\n' >> "$(SOURCE_DIR)/drivers/spi/Makefile"; \
		printf '\nconfig FROST_SPI\n\tbool "FROST SPI controller"\n\tdepends on DM_SPI\n' >> "$(SOURCE_DIR)/drivers/spi/Kconfig"; \
	fi
	$(MAKE) -C "$(SOURCE_DIR)" O="$(OUTPUT_DIR)" CROSS_COMPILE="$(CROSS_COMPILE)" frost_vcu118_defconfig
	python3 check_config.py configs/frost_vcu118_defconfig "$(OUTPUT_DIR)/.config"
	$(MAKE) -C "$(SOURCE_DIR)" O="$(OUTPUT_DIR)" CROSS_COMPILE="$(CROSS_COMPILE)" -j$(JOBS)
	cp "$(OUTPUT_DIR)/u-boot.bin" "$@"
	cp "$(OUTPUT_DIR)/u-boot" u-boot.elf

clean:
	rm -rf "$(BUILD_DIR)/out" u-boot.bin u-boot.elf

.PHONY: firmware dtb
firmware: all dtb
	$(MAKE) -C ../apps/bootrom RISCV_PREFIX="$(CROSS_COMPILE)"
	$(MAKE) -C ../apps/fsbl RISCV_PREFIX="$(CROSS_COMPILE)"
	python3 ../../linux/opensbi_build.py --out "$(BUILD_DIR)/opensbi" \
	  --cross "$(CROSS_COMPILE)" --jobs $(JOBS)


dtb: ../../boards/vcu118/frost.dtb
../../boards/vcu118/frost.dtb: ../../boards/vcu118/dts/frost_vcu118.dts
	dtc -I dts -O dtb -o "$@" "$<"
