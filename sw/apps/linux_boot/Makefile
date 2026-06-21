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

# Builds the FROST memory images for the no-MMU Linux boot: a low-BRAM boot
# shim plus the kernel Image + DTB + initramfs in DDR. Emits both the cocotb
# $readmemh form (sw.mem / sw_ddr.mem) and the FPGA JTAG-loader form (sw.txt /
# sw_ddr.txt, dense one 32-bit word per line) consumed by fpga/load_software.
#
# NOTE (bring-up): this pulls the kernel Image + initramfs and generates the
# board DTB from the external linux-mvp tree via build_fpga_boot.py. The DTB's
# timebase / UART clock-frequency follow FPGA_CPU_CLK_FREQ (set by the FPGA
# loader per board: genesys2 = 133.33 MHz). Integration scaffolding for first
# boot; to be replaced by an in-repo build once Linux boots to a shell.
ARTIFACTS ?= $(HOME)/bigger_l0/linux-mvp/frost-artifacts

all: patch_linux_image

.PHONY: patch_linux_image

patch_linux_image: sw.mem sw.txt sw_ddr.mem sw_ddr.txt
	python3 ./patch_ret_from_exception.py ./sw_ddr.mem ./sw_ddr.txt

sw.mem sw.txt sw_ddr.mem sw_ddr.txt:
	python3 $(ARTIFACTS)/build_fpga_boot.py
	cp -f $(ARTIFACTS)/sw.mem ./sw.mem
	cp -f $(ARTIFACTS)/sw.txt ./sw.txt
	cp -f $(ARTIFACTS)/sw_ddr.mem ./sw_ddr.mem
	cp -f $(ARTIFACTS)/sw_ddr.txt ./sw_ddr.txt

clean:
	rm -f sw.mem sw.txt sw_ddr.mem sw_ddr.txt shim.elf shim.bin
