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

# Makefile for FROST CPU Cocotb verification tests
# Configures Verilator/Icarus simulation with Cocotb Python testbench

# Simulation configuration:
# Simulator choice (verilator or icarus)
SIM             ?= verilator
# HDL language (verilog or vhdl)
TOPLEVEL_LANG   ?= verilog
# Top-level module name for simulation
TOPLEVEL        ?= cpu_tb
# Python test module(s) to run (comma-separated for multiple)
COCOTB_TEST_MODULES ?= cocotb_tests.test_cpu
# Git repository root (with fallback for Docker/non-git contexts)
ROOT            ?= $(shell git rev-parse --show-toplevel 2>/dev/null || echo /workspace)
# Whether to generate a waveform file
WAVES           ?= 0

# Export variables for Cocotb
export TOPLEVEL COCOTB_TEST_MODULES TOPLEVEL_LANG SIM ROOT

# Timer speedup for simulation (1000x faster than real-time)
# This makes FreeRTOS and timer-based tests complete much faster in simulation
# Default is 1000 for simulation; set to 1 for synthesis
SIM_TIMER_SPEEDUP ?= 1000

# Compilation arguments - RTL file list (varies by toplevel)
ifeq ($(TOPLEVEL),reorder_buffer)
# Reorder Buffer unit test - minimal dependencies
COMPILE_ARGS := \
        -f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.f
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),register_alias_table)
# Register Alias Table unit test - minimal dependencies
COMPILE_ARGS := \
        -f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/register_alias_table/register_alias_table.f
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),reservation_station)
# Reservation Station unit test - minimal dependencies
COMPILE_ARGS := \
        -f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/reservation_station.f
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),cdb_arbiter)
# CDB arbiter unit test
COMPILE_ARGS := \
        -f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/cdb_arbiter/cdb_arbiter.f
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),tomasulo_wrapper)
# Tomasulo integration wrapper block test (ROB + RAT + RS + CDB arbiter)
COMPILE_ARGS := \
        -f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.f
VERILOG_SOURCES :=
else
# Full chip or CPU tests - use complete RTL
COMPILE_ARGS := \
        -f $(ROOT)/hw/rtl/frost.f \

# Conditional Verilog sources based on toplevel module
ifeq ($(TOPLEVEL),cpu_tb)
VERILOG_SOURCES := \
        $(ROOT)/hw/sim/cpu_tb.sv  # Include testbench wrapper
else
# For Verilator/Icarus, frost.sv is already in frost.f so we don't add it again
VERILOG_SOURCES :=
endif
endif

export VERILOG_SOURCES

# ---------------------------------------------------------------------------
# Icarus VPI workaround: Use testbench wrappers with flattened ports.
# Icarus VVP crashes (event.cc assertion) on very wide packed struct
# VPI-facing ports. Internal signals of any width are fine; only ports
# that cocotb drives/reads via VPI are affected. Ports up to 187 bits
# work; 352+ bits crash. The _tb wrappers expose individual scalar ports
# and connect directly to the modules' individual ICARUS ports.
# ---------------------------------------------------------------------------
ifeq ($(SIM),icarus)
COMPILE_ARGS += -DICARUS
ifeq ($(TOPLEVEL),reservation_station)
COMPILE_ARGS += $(ROOT)/hw/sim/reservation_station_tb.sv
override TOPLEVEL := reservation_station_tb
endif
ifeq ($(TOPLEVEL),cdb_arbiter)
COMPILE_ARGS += $(ROOT)/hw/sim/cdb_arbiter_tb.sv
override TOPLEVEL := cdb_arbiter_tb
endif
ifeq ($(TOPLEVEL),tomasulo_wrapper)
COMPILE_ARGS += $(ROOT)/hw/sim/tomasulo_wrapper_tb.sv
override TOPLEVEL := tomasulo_wrapper_tb
endif
endif

# Add verification infrastructure to Python path so cocotb_tests modules are importable
export PYTHONPATH := $(ROOT)/verif:$(PYTHONPATH)

# Detect number of CPU cores for parallel compilation
NUMBER_OF_CPU_CORES := $(shell nproc)

# Simulator-specific options
ifeq ($(SIM),verilator)
	# Verilator threading configuration:
	# - Runtime: Single-threaded for optimal cocotb performance (avoids VPI overhead)
	# - Build/Verilation: Multi-threaded for faster compilation
	#
	# VERILATOR_THREADS controls runtime threads (1 = single-threaded simulation)
	# -j flag during verilation enables parallel HDL-to-C++ conversion
	# VERILATOR_MAKE_FLAGS controls C++ compilation parallelism
	export VERILATOR_THREADS := 1
	export VERILATOR_MAKE_FLAGS := -j$(NUMBER_OF_CPU_CORES)

	# Extra verilator args: parallel verilation + optional waveforms
	# -Wno-UNOPTFLAT: Suppress circular combinational logic warnings from FPU stall feedback
	ifeq ($(WAVES),1)
		export EXTRA_ARGS := -j $(NUMBER_OF_CPU_CORES) --trace-fst --trace-structs -Wno-UNOPTFLAT
	else
		export EXTRA_ARGS := -j $(NUMBER_OF_CPU_CORES) -Wno-UNOPTFLAT
	endif

	# Simulation-only memory override (2MB default, allows arch tests with large data)
	# Only for toplevels that have the MEM_SIZE_BYTES parameter
	SIM_MEM_SIZE_BYTES ?= 2097152
	ifeq ($(TOPLEVEL),frost)
		EXTRA_ARGS += -GMEM_SIZE_BYTES=$(SIM_MEM_SIZE_BYTES)
	endif
endif

# Include Cocotb simulation makefile rules
include $(shell cocotb-config --makefiles)/Makefile.sim

# Add custom clean target
clean:: clean-local

.PHONY: clean-local
clean-local:
	@rm -rf dump.vcd dump.fst sw.mem results.xml sim_build
