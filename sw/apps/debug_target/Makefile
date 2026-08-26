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

# Makefile for the debug-module target program (Phase 3 M3): the debuggee the
# debug_test / debug_openocd_test benches halt, inspect, patch, step and resume.
SRC_C := ../../lib/src/uart.c main.c
# Assembly sites with exact instruction layouts (breakpoint / step targets,
# the U-mode loop, the trap entry).
EXTRA_ASM_SRC := target.S
include ../../common/common.mk
