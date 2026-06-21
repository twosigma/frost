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

# Linux-like active-code timer IRQ directed test. Force the whole program into
# cached DDR even when the generic cocotb runner is in its default BRAM tier.
override MEM_CONFIG := ddr
SRC_C := ../../lib/src/uart.c main.c
include ../../common/common.mk
