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

# Fast-BTB entries across bare M-mode and Sv39 S-mode fetch at one address.
SRC_C := ../../lib/src/uart.c main.c
# The code pages and the stub, handler and training routines sit at fixed
# page offsets, so their BTB indices stay clear of the aliased branch's.
EXTRA_ASM_SRC := pages.S
include ../../common/common.mk
