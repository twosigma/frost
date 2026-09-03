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

# FreeRTOS demo on FROST. The kernel is the vendored FreeRTOS-Kernel tree, built
# unmodified. The port layer (port_frost.c, port_frost_asm.S) is FROST-specific.

# MEM_CONFIG selects the FreeRTOS linker script. common.mk then supplies the ROM
# boot stub (DDR_BOOT_STUB) and the image split (DDR_SPLIT_SECTIONS) for the ddr
# tier.
#   bram (default): whole program in low BRAM, FreeRTOS heap and stacks included.
#   ddr:            whole program, including the FreeRTOS heap in .bss, relocated
#                   to the cached DDR region behind a ROM boot stub.
# LINKER_SCRIPT has to be set before common.mk is included, because common.mk
# assigns it with ?=.
MEM_CONFIG ?= bram

ifeq ($(MEM_CONFIG),ddr)
LINKER_SCRIPT := link_freertos_ddr.ld
else
LINKER_SCRIPT := link_freertos.ld
endif

# Third-party kernel tree, used as vendored.
FREERTOS_DIR := ../../FreeRTOS-Kernel

FREERTOS_SRC := $(FREERTOS_DIR)/tasks.c \
                $(FREERTOS_DIR)/list.c \
                $(FREERTOS_DIR)/queue.c

# heap_4 keeps its pool in a ucHeap array in .bss. FreeRTOS carves task stacks
# and kernel objects out of it, so the linker scripts define no .heap section.
FREERTOS_HEAP := $(FREERTOS_DIR)/portable/MemMang/heap_4.c

APP_SRC := main.c ../../lib/src/uart.c ../../lib/src/string.c

# FROST port layer, in place of the upstream generic RISC-V port: tick and
# critical sections in C, trap entry and context switch in assembly.
FROST_PORT_C := port_frost.c

EXTRA_ASM_SRC := port_frost_asm.S

SRC_C := $(APP_SRC) $(FROST_PORT_C) $(FREERTOS_SRC) $(FREERTOS_HEAP)

# -I. is for this app's FreeRTOSConfig.h.
FREERTOS_INCLUDES := -I$(FREERTOS_DIR)/include \
                     -I.

EXTRA_CFLAGS := $(FREERTOS_INCLUDES)

include ../../common/common.mk
