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
# Configures Verilator simulation with Cocotb Python testbench

# Simulation configuration:
SIM             := verilator
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
else ifeq ($(TOPLEVEL),fu_cdb_adapter)
# FU CDB adapter unit test
COMPILE_ARGS := \
        -f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_cdb_adapter/fu_cdb_adapter.f
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),load_queue)
# Load Queue unit test
COMPILE_ARGS := \
        -f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.f
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),store_queue)
# Store Queue unit test
COMPILE_ARGS := \
        -f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/store_queue.f
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),int_alu_shim)
# Integer ALU shim unit test
COMPILE_ARGS := \
        -f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fu_shims.f
VERILOG_SOURCES := $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv
else ifeq ($(TOPLEVEL),int_muldiv_shim)
# Integer MUL/DIV shim unit test
COMPILE_ARGS := \
        -f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fu_shims.f
VERILOG_SOURCES := $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv
else ifeq ($(TOPLEVEL),fp_add_shim)
# FP add shim unit test
COMPILE_ARGS := \
        -f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fu_shims.f
VERILOG_SOURCES := $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv
else ifeq ($(TOPLEVEL),fp_mul_shim)
# FP mul shim unit test
COMPILE_ARGS := \
        -f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fu_shims.f
VERILOG_SOURCES := $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv
else ifeq ($(TOPLEVEL),fp_div_shim)
# FP div shim unit test
COMPILE_ARGS := \
        -f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fu_shims.f
VERILOG_SOURCES := $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv
else ifeq ($(TOPLEVEL),dispatch)
# Dispatch unit test
COMPILE_ARGS := \
        -f $(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/dispatch/dispatch.f
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),branch_jump_unit)
# EX-stage branch/jump resolution unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/branch_jump_unit.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),commit_actions)
# CPU OOO commit-actions unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/commit/commit_actions.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),ex_comb_synthesizer)
# CPU OOO from_ex_comb synthesizer unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/recovery/ex_comb_synthesizer.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),early_misprediction_recovery)
# CPU OOO early misprediction recovery unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/branch_recovery/early_misprediction_recovery.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),misprediction_flush_controller)
# CPU OOO misprediction flush controller unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/branch_recovery/misprediction_flush_controller.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),branch_resolution)
# CPU OOO branch resolution unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/branch_jump_unit.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/branch_recovery/branch_resolution.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),data_mem_request_router)
# CPU OOO data-memory request router unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/memory_if/data_mem_request_router.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),frontend_validity_tracker)
# CPU OOO frontend validity/control-flow tracker unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/frontend_control/frontend_validity_tracker.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),perf_counter_aggregator)
# CPU OOO performance-counter aggregator unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/perf/perf_counter_aggregator.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),ooo_pipeline_control)
# CPU OOO pipeline-control unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/pipeline_control/ooo_pipeline_control.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),ooo_register_files)
# CPU OOO architectural register-files unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv \
        $(ROOT)/hw/rtl/lib/ram/mwp_dist_ram.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/wb_stage/generic_regfile.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/register_files/ooo_register_files.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),ras_detector)
# IF-stage RAS instruction detector unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/ras_detector.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),return_address_stack)
# IF-stage return-address stack unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/return_address_stack.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),branch_predictor)
# IF-stage branch target buffer predictor unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_predictor.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),branch_prediction_controller)
# IF-stage branch prediction controller unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_predictor.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/ras_detector.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/return_address_stack.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/branch_prediction_controller.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),prediction_metadata_tracker)
# IF-stage prediction metadata tracker unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/branch_prediction/prediction_metadata_tracker.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),control_flow_tracker)
# IF-stage control-flow holdoff tracker unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/control_flow_tracker.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),pc_increment_calculator)
# IF-stage PC increment calculator unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/pc_reg_precompute.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/pc_increment_calculator.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),pc_controller)
# IF-stage PC controller unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/control_flow_tracker.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/pc_reg_precompute.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/pc_increment_calculator.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/pc_controller.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),instruction_aligner)
# IF-stage instruction aligner unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/instruction_aligner.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),rvc_decompressor)
# IF-stage RVC decompressor unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/rvc_decompressor.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),c_ext_state)
# IF-stage C-extension state controller unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/c_ext_state.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),if_stage)
# IF-stage top-level integration test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/lib/ram/sdp_dist_ram.sv \
        $(ROOT)/hw/rtl/lib/stall_capture_reg.sv \
        -f $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.f
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),pd_stage)
# PD-stage top-level unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/c_extension/rvc_decompressor.sv \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/pd_stage/pd_stage.sv
VERILOG_SOURCES :=
else ifeq ($(TOPLEVEL),id_stage)
# ID-stage top-level unit test
COMPILE_ARGS := \
        $(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv \
        -f $(ROOT)/hw/rtl/cpu_and_mem/cpu/id_stage/id_stage.f
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
# frost.sv is already in frost.f so we don't add it again
VERILOG_SOURCES :=
endif
endif

export VERILOG_SOURCES

# Add verification infrastructure to Python path so cocotb_tests modules are importable
export PYTHONPATH := $(ROOT)/verif:$(PYTHONPATH)

# Detect number of CPU cores for parallel compilation
NUMBER_OF_CPU_CORES := $(shell nproc)

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
# -Wno-UNOPTFLAT: Suppress circular combinational logic warnings (pre-existing
#   in branch prediction / commit logic; not true functional loops)
# -Wno-MODDUP: Suppress duplicate module warnings from nested file lists
ifeq ($(WAVES),1)
	export EXTRA_ARGS := -j $(NUMBER_OF_CPU_CORES) --trace-fst --trace-structs -Wno-UNOPTFLAT -Wno-MODDUP
else
	export EXTRA_ARGS := -j $(NUMBER_OF_CPU_CORES) -Wno-UNOPTFLAT -Wno-MODDUP
endif

# Optional per-test Verilator args supplied by test_run_cocotb.py.
FROST_VERILATOR_EXTRA_ARGS ?=
ifneq ($(strip $(FROST_VERILATOR_EXTRA_ARGS)),)
	EXTRA_ARGS += $(FROST_VERILATOR_EXTRA_ARGS)
endif

# Simulation-only memory override (2MB default, allows arch tests with large data)
# Only for toplevels that have the MEM_SIZE_BYTES parameter
SIM_MEM_SIZE_BYTES ?= 2097152
ifeq ($(TOPLEVEL),frost)
	EXTRA_ARGS += -GMEM_SIZE_BYTES=$(SIM_MEM_SIZE_BYTES)
endif

# Include Cocotb simulation makefile rules
include $(shell cocotb-config --makefiles)/Makefile.sim

# Add custom clean target
clean:: clean-local

.PHONY: clean-local
clean-local:
	@rm -rf dump.vcd dump.fst sw.mem results.xml sim_build
