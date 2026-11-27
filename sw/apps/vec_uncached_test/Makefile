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

# Directed test: vector loads and stores targeting low BRAM, side-effecting
# MMIO devices (FIFO0, FIFO1, MTIME), and Svpbmt NC/IO regions across all
# addressing forms, element order, scalar-vector ordering, low-BRAM L0
# coherence and LR/SC invalidation, faults/vstart, and mid-run timer interrupts.
SRC_C := ../../lib/src/uart.c main.c
include ../../common/common.mk
