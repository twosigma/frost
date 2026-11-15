# Copyright (c) 2026 John Goodacre.
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

# L1I set coverage: every set of the L1I filled, hit, patched and cleared,
# PA[12] pairs, an over-subscribed upper set, and an Sv39 page crossing whose
# PA[12] differs from its VA[12]. L1I_TEST_BYTES (default 16384) is the
# simulated L1I size; at 32768 or more the warm-pass refill bound is checked.
L1I_TEST_BYTES ?= 16384
EXTRA_CFLAGS += -DL1I_TEST_BYTES=$(L1I_TEST_BYTES)

SRC_C := ../../lib/src/uart.c main.c
include ../../common/common.mk
