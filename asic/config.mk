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

# OpenROAD-flow-scripts design configuration for FROST on Nangate45. Run it
# with asic/orfs.py, which writes $(WORK_HOME)/sources.mk before calling the
# flow's Makefile.

export DESIGN_NAME = cpu_and_mem
export DESIGN_NICKNAME = frost
export PLATFORM = nangate45

# VERILOG_FILES: the frost.f sources, with the NIC and MAC/PCS converted by
# sv2v.
export FROST_ROOT = $(abspath $(dir $(DESIGN_CONFIG))..)
include $(WORK_HOME)/sources.mk

# Portable RTL (no FROST_XILINX_PRIMS) with the cached tier ending at the DDR
# AXI port instead of the behavioral DDR model. FROST_SRAM_MACROS builds the
# RAM wrappers' memories (hw/rtl/lib/ram) in asic/sram.
export VERILOG_DEFINES = -DSYNTHESIS -DFROST_SRAM_MACROS
export VERILOG_TOP_PARAMS = ENABLE_CACHED_TIER 1 USE_BEHAVIORAL_DDR 0
export SYNTH_CANONICALIZE_TCL = $(DESIGN_DIR)/canonicalize.tcl

# The SRAM macros that asic/openram.py generates with OpenRAM, one directory
# each, and the modules that build the wrappers' memories from them. The
# flow has the macros' abstract LEF and Liberty views but not their layouts,
# so the final GDS leaves their cells empty.
SRAM_MACRO_DIRECTORIES = $(sort $(wildcard $(FROST_ROOT)/asic/sram/macros/*))
export VERILOG_FILES += \
  $(FROST_ROOT)/asic/sram/frost_sram_1w1r.sv \
  $(FROST_ROOT)/asic/sram/frost_sram_2rw.sv
export ADDITIONAL_LEFS = $(foreach macro,$(SRAM_MACRO_DIRECTORIES),$(macro)/$(notdir $(macro)).lef)
export ADDITIONAL_LIBS = $(foreach macro,$(SRAM_MACRO_DIRECTORIES),$(macro)/$(notdir $(macro)).lib)
export GDS_ALLOW_EMPTY = sram_.*
export PRE_PDN_TCL = $(DESIGN_DIR)/sram_power.tcl
export POST_PDN_TCL = $(DESIGN_DIR)/check_power_grid.tcl

# Memories without a macro that are larger than SYNTH_MEMORY_MAX_BITS keep
# one row each, in flip-flops; smaller ones become flip-flops.
export SYNTH_MOCK_LARGE_MEMORIES = 1

export SDC_FILE = $(DESIGN_DIR)/constraint.sdc
# FROST_CORE_CLOCK_PERIOD, from asic/orfs.py run --clock-period, replaces the
# SDC's core clock period. ORFS hands the period to ABC as a delay target, and
# without this line it would hand over the SDC's default. The ABC script that
# ORFS runs does not use the target, so the netlist is the same either way.
ifneq ($(FROST_CORE_CLOCK_PERIOD),)
export ABC_CLOCK_PERIOD_IN_PS = $(FROST_CORE_CLOCK_PERIOD)
endif
# Writes reports/.../6_clock_slack.rpt for asic/orfs.py's summary.
export POST_FINAL_REPORT_TCL = $(DESIGN_DIR)/clock_slack.tcl

# Skip the formal equivalence check between the synthesized and final
# netlists. On this design it needs over 40 GB of memory and spends more than
# 13 minutes just loading the netlists.
export LEC_CHECK = 0

# The core holds the SRAM macros where asic/macro_placement.tcl puts them,
# with a 120 um ring around them: 9.57 mm by 7.28 mm with the macros' current
# sizes. The die adds 15 um on each side for the pins.
export DIE_AREA = 0 0 9600 7315
export CORE_AREA = 15 15 9585 7300
export MACRO_PLACEMENT_TCL = $(DESIGN_DIR)/macro_placement.tcl
# Place the standard cells at the lower bound of the density plus a fifth of
# the remaining room, as the platform's gcd design does.
export PLACE_DENSITY_LB_ADDON = 0.20
# Skip the repairs after global routing. On the die that the SRAM macros
# need, they take hours: with 16 threads, repairing slew and capacitance over
# the routed wires took 86 minutes, each legalization after a repair 25, and
# the timing and hold repairs over an hour more, chasing the port paths that
# the clock tree's latency fails (asic/README.md). In CI that would pass the
# six-hour limit of a job. The repairs after clock tree synthesis still run.
export SKIP_INCREMENTAL_REPAIR = 1
