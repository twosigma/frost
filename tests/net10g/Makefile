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

# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Two Sigma Open Source, LLC

SIM := verilator
TOPLEVEL_LANG := verilog
ROOT := $(abspath ../..)
RTL := $(ROOT)/hw/rtl/net10g
VERILOG_SOURCES := $(RTL)/eth10g_crc_pkg.sv $(RTL)/eth10g_pcs_pkg.sv
VERILOG_SOURCES += $(filter-out %_pkg.sv,$(sort $(wildcard $(RTL)/*.sv)))
VERILOG_SOURCES += $(sort $(wildcard $(CURDIR)/*_tb.sv))
COMPILE_ARGS += --assert
EXTRA_ARGS += -j 2
export VERILATOR_MAKE_FLAGS := -j2
export PYTHONPATH := $(ROOT)/tests:$(CURDIR):$(PYTHONPATH)
include $(shell cocotb-config --makefiles)/Makefile.sim
