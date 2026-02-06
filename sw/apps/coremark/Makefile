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

SRC_C   := ../../lib/src/uart.c coremark/core_list_join.c coremark/core_main.c coremark/core_matrix.c coremark/core_state.c coremark/core_util.c core_portme.c
INCLUDE_DIR = ./coremark

# Use ilp32f ABI (single-precision float ABI) for better Coremark performance
# The march still includes the D extension for compatibility
MABI := ilp32f

# Number of iterations (can be overridden via environment variable for different boards)
# Default: 11000 iterations for X3 at 300 MHz (~10 second runtime)
ITERATIONS ?= 11000

# Add ITERATIONS to CFLAGS before including common.mk
EXTRA_CFLAGS = '-DITERATIONS=$(ITERATIONS)' -DUART_PRINTF_ENABLE_FLOAT=1
EXTRA_LDFLAGS = -lgcc

include ../../common/common.mk
