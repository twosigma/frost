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

# Makefile for the self-modifying-code (fence.i) test application
# Stores instruction words into a DDR buffer and executes them: the fence.i
# between write and call must drain the SQ, write the L1D back, and
# invalidate the L1I + fetch buffer for the calls to see the new code.
SRC_C   := ../../lib/src/uart.c ddr_smc_test.c
include ../../common/common.mk
