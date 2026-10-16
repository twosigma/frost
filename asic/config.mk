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
# AXI port instead of the behavioral DDR model.
export VERILOG_DEFINES = -DSYNTHESIS
export VERILOG_TOP_PARAMS = ENABLE_CACHED_TIER 1 USE_BEHAVIORAL_DDR 0
export SYNTH_CANONICALIZE_TCL = $(DESIGN_DIR)/canonicalize.tcl

# Memories larger than SYNTH_MEMORY_MAX_BITS keep one row each, in flip-flops,
# until SRAM macros replace them; smaller ones become flip-flops.
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

export CORE_UTILIZATION = 40
# Nangate45's default PLACE_DENSITY (0.30) is below that utilization. Place at
# the lower bound plus a fifth of the remaining room, as the platform's gcd
# design does.
export PLACE_DENSITY_LB_ADDON = 0.20
