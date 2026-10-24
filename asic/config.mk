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

export DESIGN_NAME = platform_top
export DESIGN_NICKNAME = frost
export PLATFORM = nangate45

# VERILOG_FILES: the frost.f sources, with the NIC and MAC/PCS converted by
# sv2v.
export FROST_ROOT = $(abspath $(dir $(DESIGN_CONFIG))..)
include $(WORK_HOME)/sources.mk

# Portable RTL (no FROST_XILINX_PRIMS) with the cached tier ending at the DDR
# AXI port instead of the behavioral DDR model. FROST_SRAM_MACROS builds the
# RAM wrappers' memories (hw/rtl/lib/ram) in asic/sram. The L2 holds 256 KiB,
# where the X3's holds 2 MiB, so that the die, and the memory that the flow's
# steps need with it, fits the standard CI runners (asic/README.md).
export VERILOG_DEFINES = -DSYNTHESIS -DFROST_SRAM_MACROS
export VERILOG_TOP_PARAMS = ENABLE_CACHED_TIER 1 USE_BEHAVIORAL_DDR 0 L2_CACHE_BYTES 262144
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
# Clock tree synthesis takes its root nets, those of the clock ports, from
# -clk_nets rather than from the SDC's clocks: constraint.sdc generates each
# clock's I/O copy at a register's clock pin, on its master's net, and clock
# tree synthesis would take the copy for a second clock on that net and stop
# (CTS-0114). The other arguments are ORFS's defaults. A clock added to
# constraint.sdc needs its port here.
export CTS_ARGS = -sink_clustering_enable -repair_clock_nets \
  -clk_nets {i_clk i_clk_div4 i_nic_tx_clk i_nic_rx_clk i_jtag_tck}

# Skip the formal equivalence check between the synthesized and final
# netlists. On this design it needs over 40 GB of memory and spends more than
# 13 minutes just loading the netlists.
export LEC_CHECK = 0

# The core holds the SRAM macros where asic/macro_placement.tcl puts them,
# with a 120 um ring around them and an 800 um band for the logic between
# the top band and the instruction memory's: 5.1 mm by 6.075 mm with the
# macros' current sizes. The die adds 15 um on each side for the pins.
export DIE_AREA = 0 0 5130 6105
export CORE_AREA = 15 15 5115 6090
export MACRO_PLACEMENT_TCL = $(DESIGN_DIR)/macro_placement.tcl
# The pins go on the left and right edges, which pass the logic band, not
# on the top and bottom edges, which run along the macros.
export PLACE_PINS_ARGS = -exclude top:* -exclude bottom:*
# Place the standard cells at the lower bound of the density plus a fifth of
# the remaining room, as the platform's gcd design does.
export PLACE_DENSITY_LB_ADDON = 0.20
# Skip the repairs after global routing, which take hours: with 4 threads,
# repairing slew and capacitance over the routed wires took 82 minutes, the
# timing repair 49 more, and they raised global routing's peak memory from
# 15.6 to 21.1 GB. In CI that would pass the six-hour limit of a job. The
# repairs after clock tree synthesis still run.
export SKIP_INCREMENTAL_REPAIR = 1
# Skip the antenna repair after global routing. It has nothing to repair
# here: the platform has no antenna diode cell, and it finds no violation.
# The placement check that follows it builds a grid of the core's placement
# sites, which raised global routing's peak memory by 4.5 GB.
export SKIP_ANTENNA_REPAIR = 1
# Skip antenna repair after detailed routing too: inserting diodes would
# invalidate the saved pin access before the repair's detailed_route call.
# detail_route.tcl still checks the antennas of the final routes and writes
# reports/.../drt_antennas.log outside the repair block.
export SKIP_ANTENNA_REPAIR_POST_DRT = 1
# DETAILED_ROUTE_ARGS replaces detail_route.tcl's default arguments:
# -droute_end_iter 64 -verbose 1 -drc_report_iter_step 5. The script still
# adds -output_drc and -output_maze. The -no_pin_access option reuses the
# access points saved in global routing's database. From pin_access to each
# detailed_route call, cells and placement must stay unchanged: keep
# SKIP_INCREMENTAL_REPAIR, SKIP_ANTENNA_REPAIR, and
# SKIP_ANTENNA_REPAIR_POST_DRT at 1, and RECOVER_POWER at its default 0.
# With the 256 KiB L2 and 4 threads, this cut detailed routing's CPU time
# from 24,280 to 18,282 seconds (25%), with byte-identical routed DEF and
# no DRC or antenna violations.
export DETAILED_ROUTE_ARGS = -droute_end_iter 64 -verbose 1 \
  -drc_report_iter_step 5 -no_pin_access
