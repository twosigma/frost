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

SIM := verilator
TOPLEVEL_LANG := verilog
ROOT := $(abspath ../..)
RTL := $(ROOT)/hw/rtl/net10g
VERILOG_SOURCES := $(RTL)/eth10g_crc_pkg.sv $(RTL)/eth10g_pcs_pkg.sv
VERILOG_SOURCES += $(filter-out %_pkg.sv,$(sort $(wildcard $(RTL)/*.sv)))
# Library modules for the fault-status crossing and MAC buffers.
VERILOG_SOURCES += $(ROOT)/hw/rtl/lib/cdc/cdc_sync.sv
VERILOG_SOURCES += $(ROOT)/hw/rtl/lib/ram/sdp_block_ram_dc_init.sv
VERILOG_SOURCES += $(sort $(wildcard $(CURDIR)/*_tb.sv))
ifdef NET10G_SRAM_MACROS
VERILOG_SOURCES += $(ROOT)/asic/sram/frost_sram_1w1r.sv
VERILOG_SOURCES += $(sort $(wildcard $(ROOT)/asic/sram/macros/*/*.v))
COMPILE_ARGS += +define+FROST_SRAM_MACROS --timing --x-assign unique --x-initial 0
COCOTB_PLUSARGS += +verilator+rand+reset+2 +verilator+seed+1
endif
EXTRA_ARGS += -j 2
# Pass the same frame limit to the RTL and stimulus generators.
ifdef NET10G_MAX_FRAME_BYTES
COMPILE_ARGS += -GMAX_FRAME_BYTES=$(NET10G_MAX_FRAME_BYTES)
export NET10G_MAX_FRAME_BYTES
endif
export VERILATOR_MAKE_FLAGS := -j2
export PYTHONPATH := $(ROOT)/tests:$(CURDIR):$(PYTHONPATH)
include $(shell cocotb-config --makefiles)/Makefile.sim
