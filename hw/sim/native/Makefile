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

# Native C++ Verilator build and runner for the frost SoC toplevel.
# Uses selective signal exposure (frost_native.vlt) and keeps its build and
# staged program images under hw/sim/native/sim_build, separate from cocotb.

SHELL := /bin/bash
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..)
export ROOT

APP ?= hello_world
MEM_CONFIG ?= bram
THREADS ?= 1
ASSERTIONS ?= 1
SAVABLE ?= 0
PORTABLE ?= 0
STATIC_RUNTIME ?= 0
MAX_CYCLES ?=
EXTRA_RUN_ARGS ?=

NUMBER_OF_CPU_CORES ?= $(shell \
	cpus=$$(nproc 2>/dev/null || echo 1); \
	case "$$cpus" in ''|*[!0-9]*|0) cpus=1 ;; esac; \
	if [ -r /sys/fs/cgroup/cpu.max ]; then \
		read -r quota period _rest < /sys/fs/cgroup/cpu.max || true; \
		case "$${quota:-}:$${period:-}" in \
			''|:*|*:|*[!0-9]*:*|*:*[!0-9]*) ;; \
			*) if [ "$$quota" -gt 0 ] && [ "$$period" -gt 0 ]; then \
				cg=$$(( quota / period )); \
				[ "$$cg" -lt 1 ] && cg=1; \
				[ "$$cg" -lt "$$cpus" ] && cpus="$$cg"; \
			fi ;; \
		esac; \
	elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then \
		read -r quota _rest < /sys/fs/cgroup/cpu/cpu.cfs_quota_us || true; \
		read -r period _rest < /sys/fs/cgroup/cpu/cpu.cfs_period_us || true; \
		case "$${quota:-}:$${period:-}" in \
			''|:*|*:|*[!0-9]*:*|*:*[!0-9]*) ;; \
			*) if [ "$$quota" -gt 0 ] && [ "$$period" -gt 0 ]; then \
				cg=$$(( quota / period )); \
				[ "$$cg" -lt 1 ] && cg=1; \
				[ "$$cg" -lt "$$cpus" ] && cpus="$$cg"; \
			fi ;; \
		esac; \
	fi; \
	echo "$$cpus")

# Keep toplevel parameters aligned with tests/Makefile (TOPLEVEL=frost).
SIM_MEM_SIZE_BYTES ?= 262144
ENABLE_CACHED_TIER ?= 1
DDR_MODEL_BYTES ?= 67108864
DDR_MODEL_LATENCY ?= 80
SIM_FAST_MAINT ?= 1
MEMORY_LINK_STAGES ?= 0
MISALIGNED_HW ?= $(if $(filter 0,$(ENABLE_CACHED_TIER)),0,1)
FROST_VERILATOR_EXTRA_ARGS ?=

ifneq ($(MEM_CONFIG),bram)
ifneq ($(MEM_CONFIG),ddr)
$(error MEM_CONFIG must be bram or ddr (got '$(MEM_CONFIG)'))
endif
endif

ifneq ($(STATIC_RUNTIME),0)
ifneq ($(STATIC_RUNTIME),1)
$(error STATIC_RUNTIME must be 0 or 1 (got '$(STATIC_RUNTIME)'))
endif
endif

ARCH_TAG := $(if $(filter 1,$(PORTABLE)),x86_64,host)
STATIC_TAG := $(if $(filter 1,$(STATIC_RUNTIME)),_static,)
MODEL_TAG := t$(THREADS)_a$(ASSERTIONS)_s$(SAVABLE)_$(ARCH_TAG)$(STATIC_TAG)

SIM_BUILD ?= $(ROOT)/hw/sim/native/sim_build
MODEL_DIR := $(SIM_BUILD)/model_$(MODEL_TAG)
MODEL_BIN := $(MODEL_DIR)/frost-native
CONFIG_STAMP := $(MODEL_DIR)/.build-config
APP_STAGE_DIR := $(SIM_BUILD)/apps/$(APP)_$(MEM_CONFIG)

CXX_ARCH_FLAG := $(if $(filter 1,$(PORTABLE)),-march=x86-64,-march=native)
CXX_OPT_FAST ?= -O3
CXX_OPT_SLOW ?= -O0
CXX_OPT_GLOBAL ?= -O2
VERILATOR_VERSION := $(shell verilator --version 2>/dev/null || echo unknown)

NATIVE_DEFINES :=
VERILATOR_FLAGS := \
	--cc --exe --MMD \
	--top-module frost \
	--prefix Vtop \
	-o frost-native \
	--Mdir $(MODEL_DIR) \
	$(ROOT)/hw/sim/native/frost_native.vlt \
	-f $(ROOT)/hw/rtl/frost.f \
	--timescale 1ns/1ps \
	-Wno-UNOPTFLAT -Wno-MODDUP \
	-O3 \
	--threads $(THREADS)

ifneq ($(THREADS),1)
VERILATOR_FLAGS += -Wno-UNOPTTHREADS
endif

ifeq ($(ASSERTIONS),1)
VERILATOR_FLAGS += --assert +define+FROST_SIM_ASSERTIONS
NATIVE_DEFINES += -DFROST_NATIVE_ASSERTIONS
else ifneq ($(ASSERTIONS),0)
$(error ASSERTIONS must be 0 or 1 (got '$(ASSERTIONS)'))
endif

ifeq ($(SAVABLE),1)
VERILATOR_FLAGS += --savable
NATIVE_DEFINES += -DFROST_NATIVE_SAVABLE
else ifneq ($(SAVABLE),0)
$(error SAVABLE must be 0 or 1 (got '$(SAVABLE)'))
endif

VERILATOR_FLAGS += \
	-GMEM_SIZE_BYTES=$(SIM_MEM_SIZE_BYTES) \
	-GENABLE_CACHED_TIER=$(ENABLE_CACHED_TIER) \
	-GDDR_MODEL_BYTES=$(DDR_MODEL_BYTES) \
	-GDDR_MODEL_LATENCY=$(DDR_MODEL_LATENCY) \
	-GSIM_FAST_MAINT=$(SIM_FAST_MAINT) \
	-GMEMORY_LINK_STAGES=$(MEMORY_LINK_STAGES) \
	-GMISALIGNED_HW=$(MISALIGNED_HW)

ifneq ($(strip $(FROST_VERILATOR_EXTRA_ARGS)),)
VERILATOR_FLAGS += $(FROST_VERILATOR_EXTRA_ARGS)
endif

NATIVE_LDFLAGS ?=
STATIC_RUNTIME_LDFLAGS :=
ifeq ($(STATIC_RUNTIME),1)
STATIC_RUNTIME_LDFLAGS := -static-libstdc++ -static-libgcc -Wl,-Bstatic -latomic -Wl,-Bdynamic -Wl,--as-needed
endif
EFFECTIVE_LDFLAGS := $(strip $(STATIC_RUNTIME_LDFLAGS) $(NATIVE_LDFLAGS))
ifneq ($(EFFECTIVE_LDFLAGS),)
VERILATOR_FLAGS += -LDFLAGS "$(EFFECTIVE_LDFLAGS)"
endif

# Keep optimization level flags out of -CFLAGS so Verilator's OPT_SLOW (-O0)
# applies to generated cold/initializer translation units instead of -O3.
NATIVE_CFLAGS := $(CXX_ARCH_FLAG) -std=c++17 -Wall -Wextra -DFROST_COMPILED_THREADS=$(THREADS) $(NATIVE_DEFINES)
VERILATOR_FLAGS += -CFLAGS "$(NATIVE_CFLAGS)"

EFFECTIVE_MODEL_CONFIG := $(VERILATOR_FLAGS)|VERILATOR=$(VERILATOR_VERSION)|OPT_FAST=$(CXX_OPT_FAST)|OPT_SLOW=$(CXX_OPT_SLOW)|OPT_GLOBAL=$(CXX_OPT_GLOBAL)
shell_quote = '$(subst ','"'"',$(1))'

ifeq ($(APP),hello_world)
STOP_MARKER ?= Hello, world!
DRAIN_CYCLES ?= 10000
else
STOP_MARKER ?= <<PASS>>
DRAIN_CYCLES ?= 0
endif

RUN_ARGS := \
	--mem-dir "$(APP_STAGE_DIR)" \
	--threads "$(THREADS)" \
	--stop "$(STOP_MARKER)" \
	--drain "$(DRAIN_CYCLES)"

ifneq ($(strip $(MAX_CYCLES)),)
RUN_ARGS += --max-cycles "$(MAX_CYCLES)"
endif

ifneq ($(strip $(EXTRA_RUN_ARGS)),)
RUN_ARGS += $(EXTRA_RUN_ARGS)
endif

.PHONY: run build stage-app clean FORCE

run: build stage-app
	"$(MODEL_BIN)" $(RUN_ARGS)

build: $(MODEL_BIN)

FORCE:

$(CONFIG_STAMP): FORCE
	@mkdir -p "$(MODEL_DIR)"
	@tmp='$@.$$$$.tmp'; \
	printf '%s\n' $(call shell_quote,$(EFFECTIVE_MODEL_CONFIG)) > "$$tmp"; \
	if cmp -s "$$tmp" '$@'; then \
		rm -f "$$tmp"; \
	else \
		mv "$$tmp" '$@'; \
	fi

-include $(MODEL_DIR)/Vtop__ver.d

$(MODEL_DIR)/Vtop.mk: $(ROOT)/hw/sim/native/frost_native.vlt $(ROOT)/hw/rtl/frost.f $(CONFIG_STAMP)
	@mkdir -p "$(MODEL_DIR)"
	verilator -j "$(NUMBER_OF_CPU_CORES)" $(VERILATOR_FLAGS) "$(ROOT)/hw/sim/native/main.cpp"

$(MODEL_BIN): $(MODEL_DIR)/Vtop.mk $(ROOT)/hw/sim/native/main.cpp
	$(MAKE) -C "$(MODEL_DIR)" -f Vtop.mk -j"$(NUMBER_OF_CPU_CORES)" \
		OPT_FAST="$(CXX_OPT_FAST)" \
		OPT_SLOW="$(CXX_OPT_SLOW)" \
		OPT_GLOBAL="$(CXX_OPT_GLOBAL)"

stage-app:
	@set -euo pipefail; \
	python3 "$(ROOT)/sw/apps/compile_app.py" "$(APP)" --mem-config "$(MEM_CONFIG)"; \
	app_dir="$$(python3 -c 'import sys; sys.path.insert(0, "$(ROOT)/sw/apps"); from software_registry import app_build_directory_name; print(app_build_directory_name(sys.argv[1]))' "$(APP)")"; \
	mkdir -p "$(APP_STAGE_DIR)"; \
	cp -f "$(ROOT)/sw/apps/$$app_dir/sw.mem" "$(APP_STAGE_DIR)/sw.mem"; \
	cp -f "$(ROOT)/sw/apps/$$app_dir/sw64.mem" "$(APP_STAGE_DIR)/sw64.mem"; \
	cp -f "$(ROOT)/sw/apps/$$app_dir/sw_ddr.mem" "$(APP_STAGE_DIR)/sw_ddr.mem"

clean:
	rm -rf "$(SIM_BUILD)"
