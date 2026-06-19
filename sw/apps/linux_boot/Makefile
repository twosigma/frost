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

# Builds the cocotb memory images for the no-MMU Linux boot: a low-BRAM boot
# shim (sw.mem) plus the kernel Image + DTB in DDR (sw_ddr.mem).
#
# NOTE (bring-up): this pulls the kernel Image and DTB from the external
# linux-mvp tree via build_linux_mem.py. It is the integration scaffolding for
# first boot and will be replaced by an in-repo build once Linux boots.
ARTIFACTS ?= $(HOME)/bigger_l0/linux-mvp/frost-artifacts

all: sw.mem sw_ddr.mem

sw.mem sw_ddr.mem:
	python3 $(ARTIFACTS)/build_linux_mem.py
	cp -f $(ARTIFACTS)/sw.mem ./sw.mem
	cp -f $(ARTIFACTS)/sw_ddr.mem ./sw_ddr.mem

clean:
	rm -f sw.mem sw_ddr.mem shim.elf shim.bin
