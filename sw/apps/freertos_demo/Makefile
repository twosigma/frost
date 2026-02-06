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

# Makefile for FreeRTOS Demo on FROST RISC-V
# Uses FROST-specific port code (like coremark integration pattern)

# Use FreeRTOS-specific linker script (no heap section - FreeRTOS manages its own)
LINKER_SCRIPT := link_freertos.ld

# FreeRTOS kernel root directory (third-party, untouched)
FREERTOS_DIR := ../../FreeRTOS-Kernel

# FreeRTOS kernel core sources (untouched third-party code)
FREERTOS_SRC := $(FREERTOS_DIR)/tasks.c \
                $(FREERTOS_DIR)/list.c \
                $(FREERTOS_DIR)/queue.c

# FreeRTOS memory management (heap_4 is good general-purpose option)
FREERTOS_HEAP := $(FREERTOS_DIR)/portable/MemMang/heap_4.c

# Application sources + UART library
APP_SRC := main.c ../../lib/src/uart.c ../../lib/src/string.c

# FROST-specific port (similar to coremark's core_portme.c pattern)
FROST_PORT_C := port_frost.c

# FROST-specific port assembly (included via EXTRA_ASM_SRC)
EXTRA_ASM_SRC := port_frost_asm.S

# All C sources (no generic FreeRTOS port - we use FROST-specific one)
SRC_C := $(APP_SRC) $(FROST_PORT_C) $(FREERTOS_SRC) $(FREERTOS_HEAP)

# FreeRTOS include directories
FREERTOS_INCLUDES := -I$(FREERTOS_DIR)/include \
                     -I.

# Add FreeRTOS includes to CFLAGS
EXTRA_CFLAGS := $(FREERTOS_INCLUDES)

# Include the common build rules
include ../../common/common.mk
