#!/usr/bin/env python3

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

"""Run cocotb simulations in the frost image from the repository root.

    ./scripts/frost.py cocotb hello_world
    ./scripts/frost.py cocotb reorder_buffer
    ./scripts/frost.py cocotb --list-tests
    ./scripts/frost.py pytest
    ./scripts/frost.py pytest -k programs
    ./scripts/frost.py pytest -k unit

The cocotb and pytest shortcuts clean tests/ before running.
"""

import os
import random
import re
import signal
import subprocess
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from collections.abc import Mapping
from xml.etree import ElementTree

import pytest
import cocotb

SW_APPS_DIR = Path(__file__).resolve().parent.parent / "sw" / "apps"
sys.path.insert(0, str(SW_APPS_DIR))
try:
    from software_registry import (
        COREMARK_PRO_PROGRAMS,
        app_build_directory_name,
    )
finally:
    sys.path.pop(0)

# =============================================================================
# Test Configuration Registry
# =============================================================================


@dataclass(frozen=True)
class CocotbRunConfig:
    """Configuration for a cocotb test run."""

    python_test_module: str
    hdl_toplevel_module: str
    app_name: str | None = None  # Application name (compiled on demand)
    description: str = ""
    include_in_pytest: bool = True
    verilator_extra_args: tuple[str, ...] = ()
    # Environment overrides applied to the app build and the simulation
    # (e.g. COCOTB_MAX_CYCLES budgets or EXTRA_CFLAGS build knobs).
    extra_env: tuple[tuple[str, str], ...] = ()


# tests/Makefile turns these environment variables into Verilator arguments:
# WAVES for every toplevel, the rest as -G overrides of the frost toplevel.
MAKEFILE_BUILD_VARIABLES = (
    "WAVES",
    "SIM_MEM_SIZE_BYTES",
    "ENABLE_CACHED_TIER",
    "DDR_MODEL_BYTES",
    "DDR_MODEL_LATENCY",
    "SIM_FAST_MAINT",
)

# test_real_program sees all workloads as coremark_pro, so per-workload
# budgets belong here. Run loops and nnet once in either tier for runtime;
# each run still checks the workload's verification and success marker.
COREMARK_PRO_SIMULATION_ENV: dict[str, tuple[tuple[str, str], ...]] = {
    "coremark_pro_loops": (
        ("COCOTB_COREMARK_MAX_CYCLES", "20000000"),
        ("COCOTB_NUM_RUNS", "1"),
    ),
    "coremark_pro_nnet": (("COCOTB_NUM_RUNS", "1"),),
}

COREMARK_PRO_TESTS = {
    program.app_name: CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name=program.app_name,
        description=program.description,
        # Simulation runs each workload in its minimal CRC-verified
        # configuration. Hardware runs use the official datasets, with the
        # per-board iteration counts in software_registry.py.
        extra_env=COREMARK_PRO_SIMULATION_ENV.get(program.app_name, ()),
    )
    for program in COREMARK_PRO_PROGRAMS
}

# Check serial TX at 3.6864 MHz: eight clk_div4 cycles per UART bit.
# Programs that check UART timing against the real clock cannot use this.
UART_LINE_CHECK: dict[str, Any] = {
    "extra_env": (("FROST_UART_LINE_CHECK", "1"),),
    "verilator_extra_args": ("-GCLK_FREQ_HZ=3686400",),
}

# Single source of truth for every runnable test, keyed by test name.
TEST_REGISTRY: dict[str, CocotbRunConfig] = {
    # Real-program tests on the frost toplevel.
    "branch_pred_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="branch_pred_test",
        description="Branch and jump correctness across prediction patterns",
    ),
    "c_ext_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="c_ext_test",
        description="RV64C instructions and mixed-width calls and returns",
    ),
    "cf_ext_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="cf_ext_test",
        description="Compressed double-precision floating-point loads and stores (Zcd)",
    ),
    "call_stress": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="call_stress",
        description="Repeated and nested calls with compressed instructions",
    ),
    "coremark": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="coremark",
        description=("CoreMark benchmark with profiling counters disabled"),
    ),
    "coremark_profile": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="coremark",
        description=(
            "CoreMark benchmark and profile report with profiling counters enabled"
        ),
        verilator_extra_args=("-GPERF_COUNTERS=1",),
        extra_env=(("FROST_EXPECT_PERF_COUNTERS", "1"),),
    ),
    **COREMARK_PRO_TESTS,
    "ddr_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ddr_test",
        description="Cached DDR loads and stores through the cache hierarchy",
    ),
    "dma_torture": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="dma_torture",
        description=("DMA coherence with CPU caches and atomics"),
    ),
    "nic_loopback": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="nic_loopback",
        description=(
            "NIC frame loopback through DDR rings, with completion and interrupt checks"
        ),
    ),
    "nic_echo": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="nic_echo",
        description=("Interrupt-driven NIC echo checked by a simulated wire peer"),
    ),
    "ddr_exec_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ddr_exec_test",
        description="Instruction fetch and execution from cached DDR",
    ),
    "ddr_smc_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ddr_smc_test",
        description="Self-modifying DDR code becomes visible after fence.i",
    ),
    "smc_fencei_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="smc_fencei_test",
        description="Self-modifying DDR code across fence.i timing and cache-state "
        "variations",
    ),
    "ddr_heap_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ddr_heap_test",
        description="Large heap allocations in cached DDR",
    ),
    "ddr_mlp_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ddr_mlp_test",
        description=(
            "Overlapping DDR cache misses with 4 KiB L1D/L2 caches and profiling "
            "counters"
        ),
        verilator_extra_args=(
            "-GL1_CACHE_BYTES=4096",
            "-GL2_CACHE_BYTES=4096",
            "-GPERF_COUNTERS=1",
        ),
    ),
    "csr_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="csr_test",
        description=("Machine-mode CSR writes and cycle/instret counter controls"),
    ),
    "instret_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="instret_test",
        description=(
            "Exact instruction retirement counts across fences and traps, with serial "
            "TX checks"
        ),
        **UART_LINE_CHECK,
    ),
    "umode_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="umode_test",
        description="User-mode traps, privilege checks, and counter permissions",
    ),
    "pma_fault_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="pma_fault_test",
        description=(
            "Physical-memory access faults with precise trap state and fault priority"
        ),
    ),
    "fs_off_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="fs_off_test",
        description=(
            "F/D instructions trap without memory effects when mstatus.FS is Off"
        ),
    ),
    "vm_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="vm_test",
        description=(
            "Sv39 data translation, permissions, and precise faults through MPRV"
        ),
    ),
    "slot2_fault_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="slot2_fault_test",
        description=("Precise fetch faults on the second instruction of a pair"),
    ),
    "itlb_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="itlb_test",
        description=(
            "Sv39 instruction fetch in supervisor and user modes, including cached DDR"
        ),
        # Case Z's repeated L1I eviction and L1D writeback exceed the default
        # 500k-cycle budget from DDR.
        extra_env=(("COCOTB_MAX_CYCLES", "2000000"),),
    ),
    "debug_test": CocotbRunConfig(
        python_test_module="cocotb_tests.debug.test_debug",
        hdl_toplevel_module="frost",
        app_name="debug_target",
        description=(
            "JTAG debug control, register and memory access, stepping, and reset"
        ),
    ),
    "debug_openocd_test": CocotbRunConfig(
        python_test_module="cocotb_tests.debug.test_debug_openocd",
        hdl_toplevel_module="frost",
        app_name="debug_target",
        description=(
            "OpenOCD debug integration (optional unless FROST_REQUIRE_OPENOCD=1)"
        ),
    ),
    "satp_drain_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="satp_drain_test",
        description=(
            "Committed DDR stores drain before satp and mstatus writes retire"
        ),
    ),
    "plic_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="plic_test",
        description=("PLIC register behavior and interrupt claim/complete handling"),
    ),
    "sstc_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="sstc_test",
        description=(
            "Sstc timer access controls and delegated supervisor timer interrupts"
        ),
    ),
    "ns16550_irq_console_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ns16550_irq_console_test",
        description=("ns16550 console output through PLIC interrupt handlers"),
    ),
    "ad_fault_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ad_fault_test",
        description=(
            "Sv39 faults after PTE accessed/dirty bits are cleared, and demand-page "
            "copying"
        ),
    ),
    "smode_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="smode_test",
        description=("Supervisor-mode traps, returns, delegation, and CSR permissions"),
    ),
    "csr_rmw_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="csr_rmw_test",
        description=(
            "CSR read-modify-write and trap-entry swaps with profiling counters enabled"
        ),
        verilator_extra_args=("-GPERF_COUNTERS=1",),
    ),
    "pause_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="pause_test",
        description=(
            "PAUSE skips store draining; FENCE waits (profiling counters enabled)"
        ),
        verilator_extra_args=("-GPERF_COUNTERS=1",),
    ),
    "perf_off_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="perf_off_test",
        description=(
            "Profiling CSRs read zero with counters disabled; cycle and instret still "
            "count"
        ),
    ),
    "wfi_mepc_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="wfi_mepc_test",
        description=("Timer interrupts save the PC after a waiting WFI"),
    ),
    "wfi_seed_recovery": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="wfi_seed_recovery",
        description=(
            "A wrong-path WFI cannot set the interrupt resume PC during recovery"
        ),
    ),
    "wfi_drain_mepc_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="wfi_drain_mepc_test",
        description="Timer-interrupt mepc at WFI while a store drains (DDR tier only)",
    ),
    "drain_trapframe_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="drain_trapframe_test",
        description=(
            "Trap-frame stores survive L1D eviction with a small L2 and slow DDR"
        ),
        # Small L2 and slow memory stress store drain and dirty writeback.
        verilator_extra_args=("-GL2_CACHE_BYTES=4096", "-GDDR_MODEL_LATENCY=70"),
    ),
    "mret_timer_resume_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="mret_timer_resume_test",
        description="A pending timer interrupt after MRET to user mode saves the "
        "target PC",
    ),
    "restore_window_stress": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="restore_window_stress",
        description=(
            "Timer interrupts across exception-return restore windows with a small L2 "
            "and slow DDR"
        ),
        # Small L2 and slow memory extend cold SC/load and store-drain windows.
        # These settings detect a stale interrupt resume PC during restoration.
        verilator_extra_args=("-GL2_CACHE_BYTES=4096", "-GDDR_MODEL_LATENCY=70"),
    ),
    "mtimer_stress": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="mtimer_stress",
        description=(
            "Machine-timer interrupts and MRET keep making progress across timer phases"
        ),
    ),
    "mret_drain_deadlock": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="mret_drain_deadlock",
        description=(
            "MRET completes after cached stores drain, with a small L2 and slow DDR"
        ),
        # Small L2 and slow memory keep committed stores draining as the MRET reaches the head.
        verilator_extra_args=("-GL2_CACHE_BYTES=4096", "-GDDR_MODEL_LATENCY=70"),
    ),
    "wfi_lost_tick": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="wfi_lost_tick",
        description="Timer ticks keep arriving across Linux-style WFI idle and "
        "interrupt masking",
    ),
    "irq_mie_window": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="irq_mie_window",
        description="A pending timer interrupt is taken in a one-instruction MIE "
        "window",
    ),
    "ns16550_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ns16550_test",
        description=(
            "ns16550 register behavior, transmit status timing, and serial TX output"
        ),
    ),
    "uart_burst": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="uart_burst",
        description=(
            "Back-to-back UART stores produce each serial TX byte once, in order"
        ),
        **UART_LINE_CHECK,
    ),
    "clint_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="clint_test",
        description="CLINT aliases share native timer registers and deliver timer "
        "interrupts",
    ),
    "jal_target_seam": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="jal_target_seam",
        description=(
            "JAL redirect after a taken branch (use FROST_COCOTB_MEM_CONFIG=ddr)"
        ),
    ),
    "writecount_probe": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="writecount_probe",
        description=(
            "LR.W sign extension in inode write counts (use DDR tier for cached "
            "coverage)"
        ),
    ),
    "mem_divergence_probe": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="mem_divergence_probe",
        description=(
            "Cold and warm DDR reads agree after cache eviction and partial stores"
        ),
        include_in_pytest=False,
        extra_env=(("EXTRA_CFLAGS", "-DN_ROUNDS=8"),),
        verilator_extra_args=("-GL2_CACHE_BYTES=4096", "-GDDR_MODEL_LATENCY=70"),
    ),
    "bram_reload": CocotbRunConfig(
        python_test_module="cocotb_tests.test_bram_reload",
        hdl_toplevel_module="frost",
        app_name="hello_world",
        description=(
            "JTAG-style BRAM reload restores boot after the program image is "
            "overwritten"
        ),
    ),
    # Linux boots in fpga/hw_regression.py and fpga/linux_boot_soak.py.
    # Simulation exercises OpenSBI and isolated kernel instruction patterns.
    "opensbi_smoke": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="opensbi_smoke",
        description=(
            "OpenSBI boot and SBI services from an S-mode payload (fixed memory layout)"
        ),
        extra_env=(("COCOTB_MAX_CYCLES", "10000000"), ("COCOTB_NUM_RUNS", "1")),
    ),
    "linux_irq_ddr_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="linux_irq_ddr_test",
        description="Linux-style timer interrupts preserve context with DDR code, "
        "data, and stack",
    ),
    "amo_irq_torture": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="amo_irq_torture",
        description=(
            "Timer interrupts preserve DDR atomic effects (hardware-scale; simulate "
            "amo_irq_torture_sim)"
        ),
        include_in_pytest=False,
    ),
    "tick_torture": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="tick_torture",
        description=(
            "CLINT timer re-arming under DDR traffic (hardware-scale; simulate "
            "tick_torture_sim)"
        ),
        include_in_pytest=False,
    ),
    "amo_irq_torture_jitter": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="amo_irq_torture",
        description=(
            "Timer interrupts preserve DDR atomic effects with latency jitter "
            "(hardware-scale workload)"
        ),
        include_in_pytest=False,
        verilator_extra_args=("-GDDR_MODEL_LATENCY_JITTER=19",),
    ),
    # Fixed simulation scales for CLINT re-arm and AMO/IRQ flush tests.
    # extra_env overrides external EXTRA_CFLAGS; use the base entries for
    # custom scales. The bench's app_name-based budgets still apply.
    "amo_irq_torture_sim": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="amo_irq_torture",
        description=(
            "Timer interrupts preserve DDR atomic effects (simulation-scale workload)"
        ),
        extra_env=(("EXTRA_CFLAGS", "-DAMO_TORTURE_ITERS=256"),),
    ),
    "tick_torture_sim": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="tick_torture",
        description=(
            "CLINT timer re-arming under DDR traffic (simulation-scale workload)"
        ),
        extra_env=(("EXTRA_CFLAGS", "-DTARGET_TICKS=64 -DWORKSET_WORDS=65536u"),),
    ),
    "linux_irq_active_ddr_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="linux_irq_active_ddr_test",
        description="Linux-style timer interrupts preserve context during DDR calls "
        "and returns",
    ),
    "linux_clksrc_faithful": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="linux_clksrc_faithful",
        description="CLINT enable-then-arm timer sequence with MIE-enabled WFI and DDR "
        "traffic",
        verilator_extra_args=("-GL2_CACHE_BYTES=4096", "-GDDR_MODEL_LATENCY=70"),
    ),
    "trap_s2l_fwd": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="trap_s2l_fwd",
        description="Cached store-to-load visibility across Linux-style trap entry and "
        "return",
        verilator_extra_args=("-GL2_CACHE_BYTES=4096", "-GDDR_MODEL_LATENCY=70"),
    ),
    "linux_irq_stack_slot_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="linux_irq_stack_slot_test",
        description=(
            "Timer interrupts preserve DDR return-address slots, with strict IRQ "
            "precision checks"
        ),
        extra_env=(
            ("FROST_IRQ_PRECISION_CHECK", "1"),
            ("FROST_IRQ_PRECISION_STRICT", "1"),
        ),
    ),
    "linux_irq_find_next_slot_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="linux_irq_find_next_slot_test",
        description="Timer interrupts preserve DDR return-address slots in a "
        "find-next-bit loop",
    ),
    "lq_stale_slot_probe": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="lq_stale_slot_probe",
        description=(
            "Load data stays with its slot across flush/tag reuse with slow, jittered, "
            "reordered DDR"
        ),
        verilator_extra_args=(
            "-GDDR_MODEL_LATENCY=150",
            "-GDDR_MODEL_LATENCY_JITTER=19",
            "-GDDR_MODEL_REORDER=1",
        ),
        extra_env=(
            ("EXTRA_CFLAGS", "-DSTALE_ITERS=512"),
            ("COCOTB_MAX_CYCLES", "16000000"),
            ("COCOTB_NUM_RUNS", "1"),
        ),
    ),
    "ptw_coherence_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ptw_coherence_test",
        description=(
            "Sv39 walks see dirty L1D page tables without an intervening sfence.vma"
        ),
    ),
    "ddr_atomic_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ddr_atomic_test",
        description="Word-form LR/SC and AMO operations in cached DDR",
        include_in_pytest=True,
    ),
    "pde_return_hazard": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="pde_return_hazard",
        description="Return values survive register restores in a "
        "pde_subdir_find-style epilogue (DDR tier only)",
        # The app forces MEM_CONFIG=ddr. Use a small L2 and slow DDR for misses.
        # This variant does not exercise window_cannot_serve resteering.
        verilator_extra_args=("-GL2_CACHE_BYTES=4096", "-GDDR_MODEL_LATENCY=70"),
    ),
    "freertos_demo": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="freertos_demo",
        description=(
            "FreeRTOS queues, mutexes, atomics, and tick-driven task switching"
        ),
        # Allow for timer ticks spaced 10,000 cycles apart in simulation.
        extra_env=(("COCOTB_MAX_CYCLES", "1000000"),),
    ),
    "fpu_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="fpu_test",
        description="Floating-point arithmetic, rounding, and conversion checks",
    ),
    "fpu_assembly_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="fpu_assembly_test",
        description="Floating-point load-use and wrong-path hazards",
    ),
    "fp_dyn_rm_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="fp_dyn_rm_test",
        description=(
            "Dynamic FP rounding traps for reserved frm values and works for valid "
            "modes"
        ),
    ),
    "hello_world": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="hello_world",
        description="Hello World output reaches the serial TX pin",
        **UART_LINE_CHECK,
    ),
    "isa_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="isa_test",
        description="Instruction checks for RV64GCB and supported extensions",
    ),
    "memory_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="memory_test",
        description="Arena allocation and malloc/free behavior",
    ),
    "rv64_smoke": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="rv64_smoke",
        description="RV64I arithmetic, shifts, and memory access",
    ),
    "rv64_amo_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="rv64_amo_test",
        description=(
            "Doubleword AMO and LR/SC results, plus word-atomic byte selection"
        ),
    ),
    "packet_parser": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="packet_parser",
        description="FIX message parsing through MMIO FIFOs",
    ),
    "print_clock_speed": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="print_clock_speed",
        description="UART output of the configured FPGA clock frequency",
    ),
    "spanning_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="spanning_test",
        description="32-bit instructions spanning fetch-word boundaries",
    ),
    "sprintf_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="sprintf_test",
        description="sprintf and snprintf output formatting",
    ),
    "strings_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="strings_test",
        description="String, character, and integer-conversion library checks",
    ),
    "ras_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ras_test",
        description="Call/return correctness across return-stack depth and instruction "
        "alignments",
    ),
    "ras_stress_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ras_stress_test",
        description="Calls and returns mixed with branches and function pointers",
    ),
    "ras_slot_bench": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ras_slot_bench",
        description=(
            "Return prediction in both bundle slots, checked with profiling counters"
        ),
        verilator_extra_args=("-GPERF_COUNTERS=1",),
    ),
    "ras_repair_bench": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ras_repair_bench",
        description=(
            "Return-stack repair after wrong-path pops and pushes, checked with "
            "profiling counters"
        ),
        verilator_extra_args=("-GPERF_COUNTERS=1",),
    ),
    "tomasulo_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="tomasulo_test",
        description="Register and memory dependencies through out-of-order execution",
    ),
    "tomasulo_perf": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="tomasulo_perf",
        description=(
            "IPC benchmarks and profile-counter consistency with profiling enabled"
        ),
        verilator_extra_args=("-GPERF_COUNTERS=1",),
        extra_env=(
            ("FROST_EXPECT_PERF_COUNTERS", "1"),
            ("EXTRA_CFLAGS", "-DTOMASULO_PERF_ENABLE_PROFILE=1"),
        ),
    ),
    "uart_echo": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="uart_echo",
        description="UART receive and echo with simulated serial input",
    ),
    # Fetch-latency fuzz: the same real programs with the simulation-only
    # variable-latency fetch provider (random i_instr_valid gaps), which
    # exercises the front end's handling of invalid fetch cycles. Kept
    # adjacent so consecutive runs reuse one FETCH_VALID_FUZZ=1 build.
    "hello_world_fetch_fuzz": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="hello_world",
        description="Hello World with randomized fetch latency",
        verilator_extra_args=("-GFETCH_VALID_FUZZ=1",),
    ),
    "branch_pred_test_fetch_fuzz": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="branch_pred_test",
        description="Branch and jump correctness with randomized fetch latency",
        verilator_extra_args=("-GFETCH_VALID_FUZZ=1",),
    ),
    "c_ext_test_fetch_fuzz": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="c_ext_test",
        description="RV64C instructions and alignment with randomized fetch latency",
        verilator_extra_args=("-GFETCH_VALID_FUZZ=1",),
    ),
    "call_stress_fetch_fuzz": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="call_stress",
        description="Calls and returns with randomized fetch latency",
        verilator_extra_args=("-GFETCH_VALID_FUZZ=1",),
    ),
    "itlb_test_fetch_fuzz": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="itlb_test",
        description=(
            "Sv39 fetch with randomized latency (BRAM fetch only; cached-fetch cases "
            "disabled)"
        ),
        verilator_extra_args=("-GFETCH_VALID_FUZZ=1",),
        extra_env=(("EXTRA_CFLAGS", "-DITLB_NO_CACHED_FETCH"),),
    ),
    "served_window_resteer_fetch_fuzz": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="served_window_resteer",
        description=(
            "Fetch redirects to a delayed branch-target window with randomized latency"
        ),
        verilator_extra_args=("-GFETCH_VALID_FUZZ=1",),
    ),
    "fetch_lead_repro": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="fetch_lead_repro",
        description=(
            "Spanning instructions after a mixed-width bundle on a cold DDR fetch"
        ),
    ),
    "fetch_stall_repro": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="fetch_stall_repro",
        description="32-bit instructions advance the PC by four bytes across DDR fetch "
        "stalls",
    ),
    "window_skip_repro": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="window_skip_repro",
        description=(
            "Fall-through instructions survive recovery from a mispredicted taken "
            "branch"
        ),
        extra_env=(("COCOTB_MAX_CYCLES", "4000000"),),
    ),
    "window_skip_repro_fetch_fuzz": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="window_skip_repro",
        description=(
            "Fall-through instructions survive branch recovery with randomized fetch "
            "latency"
        ),
        include_in_pytest=False,
        extra_env=(("COCOTB_MAX_CYCLES", "8000000"),),
        verilator_extra_args=("-GFETCH_VALID_FUZZ=1",),
    ),
    # Unit benches (no application), starting with the Tomasulo back end
    "reorder_buffer": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.reorder_buffer.test_reorder_buffer",
        hdl_toplevel_module="reorder_buffer",
        description=(
            "Reorder-buffer allocation, completion, in-order retirement, and recovery"
        ),
    ),
    "register_alias_table": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.register_alias_table.test_register_alias_table",
        hdl_toplevel_module="register_alias_table",
        description="Register renaming and checkpoint recovery",
    ),
    "rs_issue2_selector": CocotbRunConfig(
        python_test_module=(
            "cocotb_tests.tomasulo.reservation_station.test_rs_issue2_selector"
        ),
        hdl_toplevel_module="rs_issue2_selector",
        description="INT-RS second-issue selection matches a serial reference",
    ),
    "reservation_station": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.reservation_station.test_reservation_station",
        hdl_toplevel_module="reservation_station",
        description=(
            "Reservation-station dispatch, wakeup, and issue with INT features at "
            "eight-entry capacity"
        ),
        verilator_extra_args=(
            # The shipped INT station is dual-issue; build the directed suite
            # against that elaboration rather than the single-port default.
            "-GDUAL_ISSUE=1",
            "-GALLOC_INDEXED_REPAIR=1",
            "-GDISPATCH_REPAIR_BYPASS=0",
            "-GISSUE_REPAIR_BYPASS=0",
            "-GSPECULATIVE_DATA_WRITES=1",
            "-GBROADCAST_FREE_SOURCE_VALUES=1",
            "-GISSUE_CDB_TAG_SHADOW=1",
            "-GTAG_INDEXED_BRANCH_PAYLOAD=1",
        ),
    ),
    "rs_issue2_shamt": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.reservation_station.test_rs_issue2_shamt",
        hdl_toplevel_module="reservation_station",
        description=(
            "Second-issue shift amounts stay with their operands through stalls and "
            "recovery"
        ),
        verilator_extra_args=(
            "-GDUAL_ISSUE=1",
            "-GTAG_INDEXED_BRANCH_PAYLOAD=1",
            "-GHAS_SRC3=0",
            "-GALLOC_INDEXED_REPAIR=1",
            "-GDISPATCH_REPAIR_BYPASS=0",
            "-GISSUE_REPAIR_BYPASS=0",
            "-GSPECULATIVE_DATA_WRITES=1",
            "-GBROADCAST_FREE_SOURCE_VALUES=1",
            "-GISSUE_CDB_TAG_SHADOW=1",
            "-GTRACK_INT_WRITEBACK_HINT=1",
            "-GCAPTURE_PRIMARY_EFFECTIVE_OPERANDS=1",
        ),
    ),
    "cdb_arbiter": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.cdb_arbiter.test_cdb_arbiter",
        hdl_toplevel_module="cdb_arbiter",
        description="CDB arbitration priority and result delivery",
    ),
    "fu_cdb_adapter": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.fu_cdb_adapter.test_fu_cdb_adapter",
        hdl_toplevel_module="fu_cdb_adapter",
        description="FU completion buffering, backpressure, and flush handling",
    ),
    "fu_cdb_adapter_payload_no_refill": CocotbRunConfig(
        python_test_module=(
            "cocotb_tests.tomasulo.fu_cdb_adapter.test_fu_cdb_adapter_payload_no_refill"
        ),
        hdl_toplevel_module="fu_cdb_adapter",
        description="FU CDB payload writes with grant-refill qualification disabled",
        verilator_extra_args=("-GALLOW_GRANT_REFILL_PAYLOAD_WRITE=0",),
    ),
    "load_queue": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.load_queue.test_load_queue",
        hdl_toplevel_module="load_queue",
        description=("Load-queue ordering, completion, atomics, and recovery"),
    ),
    "load_queue_no_prepare_busy": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.load_queue.test_load_queue",
        hdl_toplevel_module="load_queue",
        description="Load-queue behavior with busy-port load preparation disabled",
        verilator_extra_args=("-GPREPARE_LOAD_WHILE_BUSY=0",),
        extra_env=(("FROST_TEST_PREPARE_LOAD_WHILE_BUSY", "0"),),
    ),
    "load_queue_sq_forward": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.load_queue.test_load_queue",
        hdl_toplevel_module="load_queue",
        description="Load-queue behavior with store-to-load forwarding enabled",
        verilator_extra_args=("-GENABLE_SQ_FORWARD_FAST_PATH=1",),
        extra_env=(("FROST_TEST_SQ_FORWARD_FAST_PATH", "1"),),
    ),
    **{
        f"lq_l0_cache_{depth}": CocotbRunConfig(
            python_test_module="cocotb_tests.tomasulo.load_queue.test_lq_l0_cache",
            hdl_toplevel_module="lq_l0_cache",
            description=f"{depth}-entry L0 load-cache data and coherence",
            verilator_extra_args=(f"-GDEPTH={depth}",),
            extra_env=(("FROST_TEST_L0_DEPTH", str(depth)),),
        )
        for depth in (128, 256)
    },
    "store_queue": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.store_queue.test_store_queue",
        hdl_toplevel_module="store_queue",
        description="Store-queue allocation, forwarding, committed writes, and "
        "recovery",
    ),
    "int_alu_shim": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.fu_shims.test_int_alu_shim",
        hdl_toplevel_module="int_alu_shim",
        description=("Integer ALU results and shift/rotate amounts"),
    ),
    "int_alu_shim_shift_hint": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.fu_shims.test_int_alu_shim",
        hdl_toplevel_module="int_alu_shim",
        description=("Integer ALU results with captured shift amounts enabled"),
        verilator_extra_args=("-GUSE_SHIFT_AMOUNT_HINT=1",),
    ),
    "divider": CocotbRunConfig(
        python_test_module="cocotb_tests.ex_stage.test_divider",
        hdl_toplevel_module="divider",
        description=("RV64 division results, latency, backpressure, and cancellation"),
        verilator_extra_args=("-GWIDTH=64",),
    ),
    "int_muldiv_shim": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.fu_shims.test_int_muldiv_shim",
        hdl_toplevel_module="int_muldiv_shim",
        description=(
            "Mixed-width multiplication and division results, scheduling, and recovery"
        ),
    ),
    "int_muldiv_shim_full_width": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.fu_shims.test_int_muldiv_shim",
        hdl_toplevel_module="int_muldiv_shim",
        description="Integer MUL/DIV behavior with MULW using the full-width "
        "multiplier",
        verilator_extra_args=("-GSHORT_WORD_OPS=0",),
        extra_env=(("FROST_TEST_SHORT_WORD_OPS", "0"),),
    ),
    "fp_shim": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.fu_shims.test_fp_shim",
        hdl_toplevel_module="fp_shim",
        description=(
            "FP engine handoff, result tags, and flush handling through the shim"
        ),
    ),
    "fp_engine_equiv": CocotbRunConfig(
        python_test_module="cocotb_tests.ex_stage.test_fp_engine",
        hdl_toplevel_module="fp_engine_equiv_harness",
        description=(
            "F/D compute results and flags match Berkeley SoftFloat, including "
            "cancellation"
        ),
    ),
    "dispatch": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.dispatch.test_dispatch",
        hdl_toplevel_module="dispatch",
        description="Instruction dispatch, operand resolution, and resource stalls",
    ),
    "branch_jump_unit": CocotbRunConfig(
        python_test_module="cocotb_tests.ex_stage.test_branch_jump_unit",
        hdl_toplevel_module="branch_jump_unit",
        description="Branch and jump target resolution",
    ),
    "commit_actions": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.commit.test_commit_actions",
        hdl_toplevel_module="commit_actions",
        description="Commit register writes, CSR writeback, and instruction retirement "
        "counts",
    ),
    "ex_comb_synthesizer": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.recovery.test_ex_comb_synthesizer",
        hdl_toplevel_module="ex_comb_synthesizer",
        description=("Recovery output priority and independent BTB update selection"),
    ),
    "early_misprediction_recovery": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.recovery.test_early_misprediction_recovery",
        hdl_toplevel_module="early_misprediction_recovery",
        description="Early branch-misprediction recovery control",
    ),
    "misprediction_flush_controller": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.recovery.test_misprediction_flush_controller",
        hdl_toplevel_module="misprediction_flush_controller",
        description="Misprediction flush control and checkpoint release",
    ),
    "branch_resolution": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.recovery.test_branch_resolution",
        hdl_toplevel_module="branch_resolution",
        description="Branch outcomes and misprediction detection during recovery",
    ),
    "data_mem_response_mux": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.memory.test_data_mem_response_mux",
        hdl_toplevel_module="data_mem_response_mux_tb",
        description="Portable response selection matches the reference through the "
        "memory router",
    ),
    "data_mem_response_mux_xilinx": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.memory.test_data_mem_response_mux",
        hdl_toplevel_module="data_mem_response_mux_tb",
        description="Xilinx LUT response selection matches the reference through the "
        "memory router",
        verilator_extra_args=("+define+FROST_XILINX_PRIMS",),
    ),
    "data_mem_request_router": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.memory.test_data_mem_request_router",
        hdl_toplevel_module="data_mem_request_router",
        description=(
            "Memory-request arbitration, device staging, store draining, and flush "
            "handling"
        ),
    ),
    "trap_unit": CocotbRunConfig(
        python_test_module="cocotb_tests.control.test_trap_unit",
        hdl_toplevel_module="trap_unit",
        description="Trap, interrupt, and return arbitration with store draining",
    ),
    "packed_tag_uram_13": CocotbRunConfig(
        python_test_module="cocotb_tests.test_sdp_packed_tag_uram",
        hdl_toplevel_module="sdp_packed_tag_uram",
        description=(
            "Packed tag RAM reads and writes with 13-bit entries and production "
            "hardware storage"
        ),
        verilator_extra_args=(
            "-GADDR_WIDTH=16",
            "-GDATA_WIDTH=13",
            "-GREAD_LATENCY=3",
            "-GSUPPORT_BULK_CLEAR=0",
        ),
        extra_env=(("PACKED_TAG_TEST_BULK_CLEAR", "0"),),
    ),
    "packed_tag_uram_13_clear": CocotbRunConfig(
        python_test_module="cocotb_tests.test_sdp_packed_tag_uram",
        hdl_toplevel_module="sdp_packed_tag_uram",
        description="Packed tag RAM reads, writes, and simulation bulk clear with "
        "13-bit entries",
        verilator_extra_args=(
            "-GADDR_WIDTH=5",
            "-GDATA_WIDTH=13",
            "-GREAD_LATENCY=3",
            "-GSUPPORT_BULK_CLEAR=1",
        ),
        extra_env=(("PACKED_TAG_TEST_BULK_CLEAR", "1"),),
    ),
    "packed_tag_uram_22": CocotbRunConfig(
        python_test_module="cocotb_tests.test_sdp_packed_tag_uram",
        hdl_toplevel_module="sdp_packed_tag_uram",
        description=(
            "Packed tag RAM reads and writes with 22-bit entries and two slots per "
            "hardware row"
        ),
        verilator_extra_args=(
            "-GADDR_WIDTH=5",
            "-GDATA_WIDTH=22",
            "-GREAD_LATENCY=3",
            "-GSUPPORT_BULK_CLEAR=0",
        ),
        extra_env=(("PACKED_TAG_TEST_BULK_CLEAR", "0"),),
    ),
    "frost_cache": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_frost_cache",
        hdl_toplevel_module="frost_cache_test_harness",
        description="L1/L2/DDR data integrity and cache maintenance",
    ),
    # Same functional suite with the sim-only fast maintenance path
    # (SIM_FAST_MAINT=1) enabled: checks that invalidate-all and writeback-all
    # behave identically when the fence.i fast path is active.
    "frost_cache_fast": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_frost_cache",
        hdl_toplevel_module="frost_cache_test_harness",
        description="L1/L2/DDR data integrity with fast fence.i maintenance",
        verilator_extra_args=("-GSIM_FAST_MAINT=1",),
    ),
    # Same suites with the memory model completing transactions of different
    # ids out of issue order, which the tagged fabric must tolerate.
    "frost_cache_reorder": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_frost_cache",
        hdl_toplevel_module="frost_cache_test_harness",
        description="L1/L2/DDR data integrity with out-of-order DDR responses",
        verilator_extra_args=("-GMEM_REORDER=1",),
    ),
    # Cache tests with multiple outstanding requests.
    "frost_cache_concurrency": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_frost_cache_concurrency",
        hdl_toplevel_module="frost_cache_test_harness",
        description="Overlapping cache requests through L1/L2/DDR",
    ),
    "frost_cache_concurrency_reorder": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_frost_cache_concurrency",
        hdl_toplevel_module="frost_cache_test_harness",
        description="Overlapping cache requests with out-of-order DDR responses",
        verilator_extra_args=("-GMEM_REORDER=1",),
    ),
    # DMA coherence: the fourth (DMA) upstream port through the coherence
    # sequencer, with the bench playing the load queue's admit/inval/release
    # handshake. In-order and out-of-order DDR completion.
    "frost_cache_dma": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_frost_cache_dma",
        hdl_toplevel_module="frost_cache_test_harness",
        description="DMA coherence through L1/L2/DDR",
    ),
    "frost_cache_dma_reorder": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_frost_cache_dma",
        hdl_toplevel_module="frost_cache_test_harness",
        description="DMA coherence with out-of-order DDR responses",
        verilator_extra_args=("-GMEM_REORDER=1",),
    ),
    # fence.i maintenance cycle-count measurement at the production cache
    # geometry (128 KiB L1D, 16 KiB L1I, 2 MiB L2). Two builds, slow
    # (FPGA-path FSM) and fast, so the speedup is readable from the logs. Not
    # part of the pytest sweep.
    "fence_speed_slow": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_fence_speed",
        hdl_toplevel_module="frost_cache_test_harness",
        description=(
            "fence.i maintenance cost at production cache sizes with the hardware FSM"
        ),
        verilator_extra_args=(
            "-GL1_CACHE_BYTES=131072",
            "-GL1I_CACHE_BYTES=16384",
            "-GL2_CACHE_BYTES=2097152",
            "-GSIM_FAST_MAINT=0",
        ),
        include_in_pytest=False,
    ),
    "fence_speed_fast": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_fence_speed",
        hdl_toplevel_module="frost_cache_test_harness",
        description=(
            "fence.i maintenance cost at production cache sizes with fast simulation "
            "maintenance"
        ),
        verilator_extra_args=(
            "-GL1_CACHE_BYTES=131072",
            "-GL1I_CACHE_BYTES=16384",
            "-GL2_CACHE_BYTES=2097152",
            "-GSIM_FAST_MAINT=1",
        ),
        include_in_pytest=False,
    ),
    # DMA-port service envelope measurement: one build per candidate lock
    # count so producer depth can be swept against the sequencer's capacity,
    # plus one at the full-system DDR model latency and one with the
    # production L2, which the write_l2_only scenario needs. Measurement
    # only, not part of the pytest sweep.
    "dma_envelope_lock3": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_dma_envelope",
        hdl_toplevel_module="frost_cache_test_harness",
        description=("DMA throughput and latency with three line locks"),
        verilator_extra_args=(
            "-GL1_CACHE_BYTES=131072",
            "-GNUM_DMA_LOCK=3",
        ),
        include_in_pytest=False,
    ),
    "dma_envelope_lock4": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_dma_envelope",
        hdl_toplevel_module="frost_cache_test_harness",
        description=("DMA throughput and latency with four line locks"),
        verilator_extra_args=(
            "-GL1_CACHE_BYTES=131072",
            "-GNUM_DMA_LOCK=4",
        ),
        include_in_pytest=False,
    ),
    "dma_envelope_lock6": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_dma_envelope",
        hdl_toplevel_module="frost_cache_test_harness",
        description=("DMA throughput and latency with six line locks"),
        verilator_extra_args=(
            "-GL1_CACHE_BYTES=131072",
            "-GNUM_DMA_LOCK=6",
        ),
        include_in_pytest=False,
    ),
    "dma_envelope_lock8": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_dma_envelope",
        hdl_toplevel_module="frost_cache_test_harness",
        description=("DMA throughput and latency with eight line locks"),
        verilator_extra_args=(
            "-GL1_CACHE_BYTES=131072",
            "-GNUM_DMA_LOCK=8",
        ),
        include_in_pytest=False,
    ),
    "dma_envelope_lock3_mem30": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_dma_envelope",
        hdl_toplevel_module="frost_cache_test_harness",
        description=(
            "DMA throughput and latency with three line locks and 30-cycle DDR latency"
        ),
        verilator_extra_args=(
            "-GL1_CACHE_BYTES=131072",
            "-GNUM_DMA_LOCK=3",
            "-GMEM_LATENCY=30",
        ),
        include_in_pytest=False,
    ),
    "dma_envelope_lock3_big_l2": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_dma_envelope",
        hdl_toplevel_module="frost_cache_test_harness",
        description=("DMA throughput and latency with three line locks and a 2 MiB L2"),
        verilator_extra_args=(
            "-GL1_CACHE_BYTES=131072",
            "-GL2_CACHE_BYTES=2097152",
            "-GNUM_DMA_LOCK=3",
        ),
        include_in_pytest=False,
    ),
    # Debug transport and debug module.
    "dtm_core": CocotbRunConfig(
        python_test_module="cocotb_tests.debug.test_dtm_core",
        hdl_toplevel_module="dtm_core",
        description=(
            "Debug transport requests, sticky status, and reset during a request"
        ),
    ),
    "debug_module": CocotbRunConfig(
        python_test_module="cocotb_tests.debug.test_debug_module",
        hdl_toplevel_module="debug_module",
        description=(
            "Each DMI request gets one reply, including requests held across reset"
        ),
    ),
    "hang_triage": CocotbRunConfig(
        python_test_module="cocotb_tests.debug.test_hang_triage",
        hdl_toplevel_module="hang_triage",
        description=(
            "Hang snapshots start on console silence without colliding with CPU output"
        ),
        verilator_extra_args=("-GQUIET_CYCLES=40", "-GREEMIT_CYCLES=100"),
    ),
    # Clock-crossing library and the NIC.
    "async_fifo": CocotbRunConfig(
        python_test_module="cocotb_tests.lib.test_async_fifo",
        hdl_toplevel_module="async_fifo",
        description=(
            "FIFO data order and flow control across unrelated clocks and reset"
        ),
    ),
    "dc_fifo": CocotbRunConfig(
        python_test_module="cocotb_tests.lib.test_dc_fifo",
        hdl_toplevel_module="dc_fifo",
        description=("UART transmit FIFO burst handling and status across two clocks"),
        verilator_extra_args=("-GDEPTH=128", "-GALMOST_FULL_MARGIN=64"),
    ),
    "cdc_gray_count": CocotbRunConfig(
        python_test_module="cocotb_tests.lib.test_cdc_gray_count",
        hdl_toplevel_module="cdc_gray_count",
        description=(
            "Event counts survive clock crossings, counter wrap, and reset with rebase"
        ),
    ),
    "nic_irq": CocotbRunConfig(
        python_test_module="cocotb_tests.nic.test_nic_irq",
        hdl_toplevel_module="nic_irq",
        description=("NIC interrupt status, masking, and moderation"),
    ),
    "nic_dma_front": CocotbRunConfig(
        python_test_module="cocotb_tests.nic.test_nic_dma_front",
        hdl_toplevel_module="nic_dma_front",
        description=(
            "NIC DMA request arbitration and response steering under backpressure"
        ),
    ),
    "nic_byte_pack": CocotbRunConfig(
        python_test_module="cocotb_tests.nic.test_nic_byte_pack",
        hdl_toplevel_module="nic_byte_pack",
        description=("NIC receive bytes become correctly strobed line writes"),
    ),
    "nic_byte_unpack": CocotbRunConfig(
        python_test_module="cocotb_tests.nic.test_nic_byte_unpack",
        hdl_toplevel_module="nic_byte_unpack",
        description=("NIC transmit lines become contiguous bytes under stalls"),
    ),
    "nic_rx_engine": CocotbRunConfig(
        python_test_module="cocotb_tests.nic.test_nic_rx_engine",
        hdl_toplevel_module="nic_rx_engine",
        description=("NIC receive frames and completions reach DDR rings in order"),
    ),
    "nic_tx_engine": CocotbRunConfig(
        python_test_module="cocotb_tests.nic.test_nic_tx_engine",
        hdl_toplevel_module="nic_tx_engine",
        description=(
            "NIC transmit descriptors produce the right frame bytes and completions"
        ),
    ),
    "nic_top": CocotbRunConfig(
        python_test_module="cocotb_tests.nic.test_nic_top",
        hdl_toplevel_module="nic_top",
        description=(
            "NIC registers and frame traffic through raw loopback and a simulated wire"
        ),
    ),
    "nic_top_unrelated_clocks": CocotbRunConfig(
        python_test_module="cocotb_tests.nic.test_nic_top",
        hdl_toplevel_module="nic_top",
        description=(
            "NIC wire traffic with independent TX/RX clocks and raw loopback disabled"
        ),
        verilator_extra_args=("-GRAW_LOOPBACK=0",),
    ),
    "nic_reset": CocotbRunConfig(
        python_test_module="cocotb_tests.nic.test_nic_reset",
        hdl_toplevel_module="nic_reset_test_harness",
        description=(
            "NIC reset drains traffic and clears state across missing or restarted "
            "clocks"
        ),
    ),
    "line_port_arbiter": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_line_port_arbiter",
        hdl_toplevel_module="line_port_arbiter_test_harness",
        description=(
            "Tagged line-port arbitration and response routing under concurrent traffic"
        ),
    ),
    "line_port_arbiter_reorder": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_line_port_arbiter",
        hdl_toplevel_module="line_port_arbiter_test_harness",
        description="Tagged line-port arbitration with out-of-order DDR responses",
        verilator_extra_args=("-GMEM_REORDER=1",),
    ),
    "line_port_axi_bridge": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_line_port_axi_bridge",
        hdl_toplevel_module="line_port_axi_bridge",
        description=(
            "AXI transfers remain valid across CPU reset and clear on AXI reset"
        ),
    ),
    "x3_ddr_init": CocotbRunConfig(
        python_test_module="cocotb_tests.test_x3_ddr_init",
        hdl_toplevel_module="x3_ddr_init",
        description=(
            "X3 DDR initialization writes the full region and waits for completion "
            "under stalls"
        ),
        verilator_extra_args=("-GREGION_BYTES=4096", "-GMAX_OUTSTANDING=4"),
        extra_env=(
            ("DDR_INIT_REGION_BYTES", "4096"),
            ("DDR_INIT_MAX_OUTSTANDING", "4"),
        ),
    ),
    "x3_ddr_init_shallow": CocotbRunConfig(
        python_test_module="cocotb_tests.test_x3_ddr_init",
        hdl_toplevel_module="x3_ddr_init",
        description=(
            "X3 DDR initialization starts with a region smaller than the default "
            "outstanding limit"
        ),
        verilator_extra_args=("-GREGION_BYTES=512",),
        extra_env=(
            ("DDR_INIT_REGION_BYTES", "512"),
            ("DDR_INIT_MAX_OUTSTANDING", "16"),
        ),
    ),
    "imem_predecode_line": CocotbRunConfig(
        python_test_module="cocotb_tests.predecode.test_imem_predecode_line",
        hdl_toplevel_module="imem_predecode_line",
        description="Instruction-line predecode matches the Python generator",
    ),
    "imem_predecode_fast_replica": CocotbRunConfig(
        python_test_module="cocotb_tests.predecode.test_imem_predecode_fast_replica",
        hdl_toplevel_module="imem_predecode",
        description=(
            "IMEM predecode programming and fetch through replica, overlay, and "
            "fallback banks"
        ),
        verilator_extra_args=(
            "-GADDR_WIDTH=4",
            "-GPC_METADATA_OVERLAY_ADDR_WIDTH=2",
            "-GUSE_INIT_FILE=0",
        ),
    ),
    "imem_predecode_capacity": CocotbRunConfig(
        python_test_module="cocotb_tests.predecode.test_imem_predecode_capacity",
        hdl_toplevel_module="imem_predecode",
        description=(
            "Predecode coverage and fetch rate at the production 128 KiB IMEM size"
        ),
        verilator_extra_args=("-GADDR_WIDTH=15", "-GUSE_INIT_FILE=0"),
    ),
    "low_bram_fetch_presenter": CocotbRunConfig(
        python_test_module="cocotb_tests.predecode.test_low_bram_fetch_presenter",
        hdl_toplevel_module="low_bram_fetch_presenter",
        description=(
            "Low-BRAM fetch retries and response delivery through stalls and retargets"
        ),
    ),
    "fetch_provider": CocotbRunConfig(
        python_test_module="cocotb_tests.predecode.test_fetch_provider",
        hdl_toplevel_module="fetch_provider",
        description="Cached-DDR fetch windows, line fills, redirects, and invalidation",
    ),
    "frontend_validity_tracker": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.frontend.test_frontend_validity_tracker",
        hdl_toplevel_module="frontend_validity_tracker",
        description="Frontend instruction validity through stalls, redirects, and "
        "replay",
    ),
    "decoded_bundle_queue": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.frontend.test_decoded_bundle_queue",
        hdl_toplevel_module="decoded_bundle_queue",
        description="Decoded bundles preserve FIFO order through backpressure and "
        "flushes",
        verilator_extra_args=("-GWIDTH=32", "-GSHADOW_WIDTH=12"),
    ),
    "decoded_bundle_queue_depth2": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.frontend.test_decoded_bundle_queue",
        hdl_toplevel_module="decoded_bundle_queue",
        description="Decoded bundles preserve FIFO order with a two-entry queue",
        verilator_extra_args=("-GWIDTH=32", "-GSHADOW_WIDTH=12", "-GDEPTH=2"),
    ),
    "perf_counter_aggregator": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.perf.test_perf_counter_aggregator",
        hdl_toplevel_module="perf_counter_aggregator",
        description="Performance-event aggregation and snapshots",
    ),
    "perf_csr_half": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.perf.test_perf_csr_half",
        hdl_toplevel_module="perf_csr_half_test_harness",
        description="Performance CSR half reads match full-counter reads on every "
        "cycle",
    ),
    "ooo_pipeline_control": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.pipeline_control.test_ooo_pipeline_control",
        hdl_toplevel_module="ooo_pipeline_control",
        description="Out-of-order pipeline stalls, replay, and recovery control",
    ),
    "ooo_register_files": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.register_files.test_ooo_register_files",
        hdl_toplevel_module="ooo_register_files",
        description="Architectural integer/FP register reads and writeback bypass",
    ),
    "return_address_stack": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.branch_prediction.test_return_address_stack",
        hdl_toplevel_module="return_address_stack",
        description="Return-stack prediction, checkpoints, and recovery",
    ),
    "branch_predictor": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.branch_prediction.test_branch_predictor",
        hdl_toplevel_module="branch_predictor",
        description="Branch-target lookup and predictor training",
    ),
    "direction_predictor": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.branch_prediction.test_direction_predictor",
        hdl_toplevel_module="direction_predictor",
        description="Branch-direction prediction and training",
    ),
    "branch_prediction_controller": CocotbRunConfig(
        python_test_module=(
            "cocotb_tests.if_stage.branch_prediction.test_branch_prediction_controller"
        ),
        hdl_toplevel_module="branch_prediction_controller",
        description="Branch-prediction control and metadata through stalls and "
        "redirects",
    ),
    "prediction_metadata_tracker": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.branch_prediction.test_prediction_metadata_tracker",
        hdl_toplevel_module="prediction_metadata_tracker",
        description="Prediction metadata stays with the right instruction through "
        "stalls and replay",
    ),
    "control_flow_tracker": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.test_control_flow_tracker",
        hdl_toplevel_module="control_flow_tracker",
        description="Fetch holdoffs after reset and control-flow redirects",
    ),
    "pc_increment_calculator": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.test_pc_increment_calculator",
        hdl_toplevel_module="pc_increment_calculator",
        description="Fetch PC increments across bundle shapes, holdoffs, and address "
        "wraparound",
    ),
    "pc_controller": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.test_pc_controller",
        hdl_toplevel_module="pc_controller",
        description="Fetch PC selection, stalls, and redirect priority",
    ),
    "dmmu": CocotbRunConfig(
        python_test_module="cocotb_tests.test_dmmu",
        hdl_toplevel_module="dmmu",
        description=(
            "Sv39 data translation, fault priority, and recovery at the MMU ports"
        ),
    ),
    "immu": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.test_immu",
        hdl_toplevel_module="immu_test_harness",
        description=(
            "Sv39 fetch translation and fault visibility across retargets and page "
            "crossings"
        ),
    ),
    "instruction_aligner": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.test_instruction_aligner",
        hdl_toplevel_module="instruction_aligner",
        description="Instruction alignment and metadata selection across fetch windows",
    ),
    "rvc_decompressor": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.test_rvc_decompressor",
        hdl_toplevel_module="rvc_decompressor",
        description=(
            "RV64C expansion, illegal flags, and source metadata match the predecode "
            "model"
        ),
    ),
    "c_ext_state": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.test_c_ext_state",
        hdl_toplevel_module="c_ext_state",
        description="Compressed-instruction buffering through stalls and control-flow "
        "changes",
    ),
    "if_stage": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.test_if_stage",
        hdl_toplevel_module="if_stage",
        description="Instruction-fetch stage integration",
    ),
    "pd_stage": CocotbRunConfig(
        python_test_module="cocotb_tests.pd_stage.test_pd_stage",
        hdl_toplevel_module="pd_stage",
        description="Instruction predecode, illegal flags, and redirects for native "
        "and compressed code",
    ),
    "id_stage": CocotbRunConfig(
        python_test_module="cocotb_tests.id_stage.test_id_stage",
        hdl_toplevel_module="id_stage",
        description="Instruction decoding and metadata propagation",
    ),
    "tomasulo_wrapper": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.tomasulo_wrapper.test_tomasulo_wrapper",
        hdl_toplevel_module="tomasulo_wrapper",
        description="Tomasulo integration with single-bus dispatch and dispatch done "
        "repair enabled",
        verilator_extra_args=("-GENABLE_DISPATCH_DONE_REPAIR=1",),
    ),
    "tomasulo_wrapper_no_early_load": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.tomasulo_wrapper.test_tomasulo_wrapper",
        hdl_toplevel_module="tomasulo_wrapper",
        description="Tomasulo integration with early load wakeup disabled and dispatch "
        "done repair enabled",
        verilator_extra_args=(
            "-GENABLE_DISPATCH_DONE_REPAIR=1",
            "-GEARLY_LOAD_WAKEUP=0",
        ),
    ),
    "tomasulo_load_wakeup": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.tomasulo_wrapper.test_load_wakeup",
        hdl_toplevel_module="tomasulo_wrapper",
        description=("Early load wakeup across dispatch, CDB contention, and recovery"),
        verilator_extra_args=("-GENABLE_DISPATCH_DONE_REPAIR=1",),
    ),
    "tomasulo_coherence": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.tomasulo_wrapper.test_tomasulo_coherence",
        hdl_toplevel_module="tomasulo_wrapper",
        description=(
            "DMA coherence races with atomics and forwarded loads at the Tomasulo "
            "wrapper"
        ),
    ),
    "tomasulo_coherence_l0_256": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.tomasulo_wrapper.test_tomasulo_coherence",
        hdl_toplevel_module="tomasulo_wrapper",
        description=(
            "DMA coherence races with a 256-entry L0 cache and early load wakeup"
        ),
        verilator_extra_args=("-GL0_CACHE_DEPTH=256",),
    ),
    "tomasulo_wrapper_split_rs": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.tomasulo_wrapper.test_tomasulo_wrapper_split_rs",
        hdl_toplevel_module="tomasulo_wrapper",
        description=(
            "Tomasulo integration with split-RS dispatch and dispatch done repair "
            "enabled"
        ),
        verilator_extra_args=(
            "-GSPLIT_RS_DISPATCH=1",
            "-GENABLE_DISPATCH_DONE_REPAIR=1",
        ),
    ),
    # Directed machine-mode trap/interrupt tests on the cpu_tb harness, which
    # feeds one instruction per ready cycle into the cpu_ooo core. Pytest
    # collects this entry so CI notices when the cpu_tb harness breaks.
    # Filter to a single function with --testcase when running by hand.
    "directed_traps": CocotbRunConfig(
        python_test_module="cocotb_tests.test_directed_traps",
        hdl_toplevel_module="cpu_tb",
        description=(
            "Precise trap and interrupt entry, WFI resume, and MRET in cpu_tb"
        ),
    ),
    # CLI-only cpu_tb suites wait on commit events through DUTInterface.
    "directed_atomics": CocotbRunConfig(
        python_test_module="cocotb_tests.test_directed_atomics",
        hdl_toplevel_module="cpu_tb",
        description="Directed LR.W/SC.W reservation checks in cpu_tb",
        include_in_pytest=False,
    ),
    "compressed": CocotbRunConfig(
        python_test_module="cocotb_tests.test_compressed",
        hdl_toplevel_module="cpu_tb",
        description="Directed and random compressed-instruction checks in cpu_tb",
        include_in_pytest=False,
    ),
}

# Registry entries that build an app and are collected by pytest. The unit
# benches have no app_name and are excluded.
REAL_PROGRAM_TESTS = [
    name
    for name, config in TEST_REGISTRY.items()
    if config.app_name is not None and config.include_in_pytest
]
REAL_PROGRAM_TEST_PARAMS = [
    pytest.param(
        name,
        id=name,
        marks=[
            pytest.mark.cocotb_real_program,
            *([pytest.mark.coremark_pro] if name in COREMARK_PRO_TESTS else []),
        ],
    )
    for name in REAL_PROGRAM_TESTS
]

UNIT_TESTS = [
    name
    for name, config in TEST_REGISTRY.items()
    if config.app_name is None and config.include_in_pytest
]
UNIT_TEST_PARAMS = [
    pytest.param(name, id=name, marks=pytest.mark.cocotb_unit) for name in UNIT_TESTS
]

# Real-program tests that do not run in the ddr memory tier
# (FROST_COCOTB_MEM_CONFIG=ddr):
#   - *_fetch_fuzz: a different -G build (FETCH_VALID_FUZZ=1), orthogonal to tier.
#   - ddr_*: already DDR-focused (execute-from-DDR, SMC, cached-region writes at
#     CACHED_BASE). A whole-program DDR relocation would be redundant or would
#     clobber their fixed-address writes, so they run in the bram-tier job only.
DDR_TIER_EXCLUDE = {
    name
    for name in REAL_PROGRAM_TESTS
    if name.endswith("_fetch_fuzz") or name.startswith("ddr_")
}


# =============================================================================
# CocotbRunner Class
# =============================================================================

PROGRAM_MEMORY_FILENAMES = ("sw.mem", "sw64.mem", "sw_ddr.mem")


def run_in_process_group(
    command: list[str], *, env: Mapping[str, str], timeout: float
) -> subprocess.CompletedProcess[str]:
    """Run command in its own process group and kill the whole group on timeout.

    subprocess.run(timeout=...) kills only its direct child, so a timed-out
    bash or make would leave the simulator it started running. Raises
    subprocess.TimeoutExpired after the group is killed.
    """
    with subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=dict(env),
        start_new_session=True,
    ) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            raise
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def _program_memory_target(program_memory_file: str, filename: str) -> str:
    """Return the sibling app image used for a tests-directory symlink."""
    return str(Path(program_memory_file).with_name(filename))


class CocotbRunner:
    """Run one cocotb simulation, managing its app build, environment, and images."""

    def __init__(
        self,
        python_test_module: str,
        hdl_toplevel_module: str,
        app_name: str | None = None,
        verilator_extra_args: tuple[str, ...] = (),
        extra_env: tuple[tuple[str, str], ...] = (),
    ) -> None:
        """Initialize the runner and apply the registry environment overrides.

        Args:
            python_test_module: Module holding the cocotb tests
                (e.g. "cocotb_tests.test_directed_traps").
            hdl_toplevel_module: Top-level HDL module name (e.g. "cpu_tb").
            app_name: Application to compile and load (e.g. "hello_world").
            verilator_extra_args: Extra Verilator args for this build.
            extra_env: (key, value) pairs written into os.environ.
        """
        self.python_test_module = python_test_module
        self.hdl_toplevel_module = hdl_toplevel_module
        self.app_name = app_name
        self.verilator_extra_args = verilator_extra_args
        # Apply overrides to both the app build and simulation.
        self.extra_env = extra_env
        # Restore overrides after each run so they cannot leak between tests.
        self._environment_before_overrides = {
            key: os.environ.get(key) for key, _ in extra_env
        }
        for key, value in extra_env:
            os.environ[key] = value
        # Seed workers share app outputs and memory symlinks. The parent
        # compiles once and removes links after all workers finish.
        self.skip_app_compile = False
        self.test_directory = Path(__file__).parent.resolve()
        self.repository_root_directory = self.test_directory.parent
        # Memory tier for app builds; the ddr CI job selects cached DDR.
        self.mem_config = os.environ.get("FROST_COCOTB_MEM_CONFIG", "bram")

    @classmethod
    def from_config(cls, config: CocotbRunConfig) -> "CocotbRunner":
        """Create a CocotbRunner from a CocotbRunConfig."""
        return cls(
            python_test_module=config.python_test_module,
            hdl_toplevel_module=config.hdl_toplevel_module,
            app_name=config.app_name,
            verilator_extra_args=config.verilator_extra_args,
            extra_env=config.extra_env,
        )

    def _verilator_extra_args_string(self) -> str:
        """Return the build args string consumed by tests/Makefile."""
        return " ".join(self.verilator_extra_args)

    def _verilator_build_signature(self) -> str:
        """Return the build-affecting signature tracked by the rebuild marker."""
        signature = self._verilator_extra_args_string()
        # Include external build overrides to prevent reusing a stale Vtop.
        external_verilator_args = os.environ.get("FROST_VERILATOR_EXTRA_ARGS", "")
        if external_verilator_args:
            signature = f"{signature} {external_verilator_args}".strip()
        makefile_settings = " ".join(
            f"{name}={os.environ[name]}"
            for name in MAKEFILE_BUILD_VARIABLES
            if name in os.environ
        )
        if makefile_settings:
            signature = f"{signature} {makefile_settings}".strip()
        return signature

    def _compile_app(self) -> bool:
        """Compile the app; return True on success or when no app is configured."""
        if not self.app_name:
            return True

        apps_dir = self.repository_root_directory / "sw" / "apps"
        sys.path.insert(0, str(apps_dir))
        try:
            from compile_app import compile_app

            return compile_app(
                self.app_name,
                verbose=True,
                mem_config=self.mem_config,
                clean_first=True,
            )
        finally:
            sys.path.pop(0)

    def _get_program_memory_file(self) -> str | None:
        """Return the sw.mem path for the current app, or None without an app."""
        if not self.app_name:
            return None
        app_dir_name = app_build_directory_name(self.app_name)
        return f"../sw/apps/{app_dir_name}/sw.mem"

    @staticmethod
    def _ensure_symlink(link: Path, target: str) -> None:
        """Point link at an existing target without replacing a correct symlink.

        Parallel seed workers share these links. Replacing one could leave a sibling's
        $readmemh without a file; accept a creation race if both targets match.
        A dangling link makes $readmemh fail quietly and memory read as zeros.
        """
        if not Path(target).exists():
            raise FileNotFoundError(
                f"program memory image '{target}' does not exist; "
                "the app build should have produced it"
            )
        try:
            if link.is_symlink() and os.readlink(link) == target:
                return
            if link.exists() or link.is_symlink():
                link.unlink()
            link.symlink_to(target)
        except FileExistsError:
            if not (link.is_symlink() and os.readlink(link) == target):
                raise

    def setup_environment(self) -> dict[str, str]:
        """Return a copy of os.environ with the simulation settings applied."""
        environment_variables = os.environ.copy()

        environment_variables["SIM"] = "verilator"
        environment_variables["ROOT"] = str(self.repository_root_directory)
        # Append external arguments after registry defaults so sweeps can
        # override settings such as FETCH_VALID_FUZZ_SEED.
        external_verilator_args = os.environ.get("FROST_VERILATOR_EXTRA_ARGS", "")
        environment_variables["FROST_VERILATOR_EXTRA_ARGS"] = " ".join(
            part
            for part in (self._verilator_extra_args_string(), external_verilator_args)
            if part
        )

        # verif/ on PYTHONPATH makes the cocotb_tests modules importable.
        verif_path = str(self.repository_root_directory / "verif")
        current_pythonpath = environment_variables.get("PYTHONPATH", "")
        if verif_path not in current_pythonpath:
            current_pythonpath = verif_path + ":" + current_pythonpath
        environment_variables["PYTHONPATH"] = current_pythonpath

        # In the ddr tier the behavioral DDR persists across reset and .data is
        # loaded in place (LMA == VMA), so a second run would see the program's
        # mutated memory. Force a single run; the bram tier keeps its default.
        if self.mem_config == "ddr":
            environment_variables["COCOTB_NUM_RUNS"] = "1"

        return environment_variables

    def check_for_failures(
        self, simulation_result: subprocess.CompletedProcess[str]
    ) -> bool:
        """Return True if the subprocess failed or cocotb reported a failure."""
        if simulation_result.returncode != 0:
            return True

        # run_simulation has already validated the fresh XML report. Without
        # captured output there are no additional log indicators to inspect.
        has_captured_output = (
            simulation_result.stdout is not None
            and simulation_result.stderr is not None
        )
        if not has_captured_output:
            return False

        failure_indicator_strings = [
            "FAILED",
            "ERROR",
            "Test Failed:",
            "AssertionError",
            "** TEST FAILED **",
            "FAIL:",
            "failed:",
        ]

        combined_output = (simulation_result.stdout or "") + (
            simulation_result.stderr or ""
        )
        for failure_indicator in failure_indicator_strings:
            if failure_indicator in combined_output:
                # Require test/fail/error context on the same line so an
                # indicator inside a file path does not count.
                output_lines = combined_output.splitlines()
                for line in output_lines:
                    if failure_indicator in line and (
                        "test" in line.lower()
                        or "fail" in line.lower()
                        or "error" in line.lower()
                    ):
                        return True

        # cocotb summary line: failed=N with N > 0.
        if "passed=0" in combined_output or "failed=" in combined_output:
            match = re.search(r"failed=(\d+)", combined_output)
            if match and int(match.group(1)) > 0:
                return True

        return False

    def _get_sim_build_dir(self, env: Mapping[str, str] | None = None) -> Path:
        """Return sim_build directory, honoring SIM_BUILD if set."""
        env_map = os.environ if env is None else env
        sim_build = env_map.get("SIM_BUILD", "")
        if sim_build:
            return Path(sim_build).expanduser().resolve()
        return self.test_directory / "sim_build"

    def _verilator_needs_rebuild(self, sim_build_dir: Path) -> bool:
        """Return True if the existing Verilator build cannot be reused.

        Existing artifacts require complete, matching markers for the toplevel,
        cocotb libs directory, and Verilator build signature. A failed verilation
        can leave generated files behind before a binary or markers exist.
        """
        toplevel_marker = sim_build_dir / ".last_toplevel"
        cocotb_libs_marker = sim_build_dir / ".last_cocotb_libs"
        verilator_extra_args_marker = sim_build_dir / ".last_verilator_extra_args"
        cocotb_libs_dir = str(
            (Path(cocotb.__file__).resolve().parent / "libs").resolve()
        )

        # Even a failed verilation can emit Vtop.mk and C++ for the old top.
        # Make would reuse those files for the next test unless we clean them.
        if (
            not toplevel_marker.exists()
            or not cocotb_libs_marker.exists()
            or not verilator_extra_args_marker.exists()
        ):
            return sim_build_dir.exists() and any(sim_build_dir.iterdir())

        try:
            last_toplevel = toplevel_marker.read_text().strip()
            last_cocotb_libs = cocotb_libs_marker.read_text().strip()
            last_verilator_extra_args = verilator_extra_args_marker.read_text().strip()
            return (
                last_toplevel != self.hdl_toplevel_module
                or last_cocotb_libs != cocotb_libs_dir
                or last_verilator_extra_args != self._verilator_build_signature()
            )
        except OSError:
            return True  # Unreadable metadata cannot qualify cached artifacts.

    def _update_verilator_toplevel_marker(self, sim_build_dir: Path) -> None:
        """Record the current build environment for future incremental checks."""
        sim_build_dir.mkdir(exist_ok=True)
        toplevel_marker = sim_build_dir / ".last_toplevel"
        cocotb_libs_marker = sim_build_dir / ".last_cocotb_libs"
        verilator_extra_args_marker = sim_build_dir / ".last_verilator_extra_args"
        toplevel_marker.write_text(self.hdl_toplevel_module)
        cocotb_libs_marker.write_text(
            str((Path(cocotb.__file__).resolve().parent / "libs").resolve())
        )
        verilator_extra_args_marker.write_text(self._verilator_build_signature())

    def _verilator_build_dir_writable(self, sim_build_dir: Path) -> bool:
        """Return True when the existing Verilator build dir can be rebuilt in place."""
        if not sim_build_dir.exists():
            return True
        if not os.access(sim_build_dir, os.W_OK):
            return False
        for path in (
            sim_build_dir / "Vtop",
            sim_build_dir / ".last_toplevel",
            sim_build_dir / ".last_cocotb_libs",
            sim_build_dir / ".last_verilator_extra_args",
        ):
            if path.exists() and not os.access(path, os.W_OK):
                return False
        return True

    def _fallback_verilator_build_dir(self) -> Path:
        """Create a user-writable temporary Verilator build directory."""
        prefix = f"{self.hdl_toplevel_module}_"
        if self.app_name:
            prefix = f"{self.app_name}_"
        return Path(
            tempfile.mkdtemp(prefix=prefix + "sim_build_", dir=tempfile.gettempdir())
        )

    def restore_environment(self) -> None:
        """Undo the registry environment overrides applied at construction."""
        for key, previous in self._environment_before_overrides.items():
            if previous is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = previous

    def run_simulation(
        self, check: bool = True, capture_output: bool = True
    ) -> subprocess.CompletedProcess[str]:
        """Run the cocotb simulation, then restore the process environment."""
        try:
            return self._run_simulation_with_overrides(
                check=check, capture_output=capture_output
            )
        finally:
            self.restore_environment()

    def _run_simulation_with_overrides(
        self, check: bool = True, capture_output: bool = True
    ) -> subprocess.CompletedProcess[str]:
        """Run the cocotb simulation under the entry's environment overrides."""
        if self.app_name and not self.skip_app_compile and not self._compile_app():
            raise RuntimeError(f"Failed to compile application: {self.app_name}")

        original_dir = os.getcwd()
        os.chdir(self.test_directory)
        env = self.setup_environment()
        sim_build_dir = self._get_sim_build_dir(env)
        env["SIM_BUILD"] = str(sim_build_dir)

        try:
            # Skip the clean so unchanged RTL builds incrementally; a changed
            # toplevel, cocotb libs, or build signature forces a full rebuild.
            needs_clean = self._verilator_needs_rebuild(sim_build_dir)

            if needs_clean and not self._verilator_build_dir_writable(sim_build_dir):
                sim_build_dir = self._fallback_verilator_build_dir()
                env["SIM_BUILD"] = str(sim_build_dir)
                needs_clean = False

            if needs_clean:
                # A failed clean (e.g. root-owned files) is not fatal.
                subprocess.run(["make", "clean"], check=False)

            # Program memory symlinks: the low BRAM image, its 64-bit data-BRAM
            # form, and the cached-region image read by the behavioral DDR.
            program_memory_file = self._get_program_memory_file()
            if program_memory_file:
                for mem_name in PROGRAM_MEMORY_FILENAMES:
                    self._ensure_symlink(
                        Path(mem_name),
                        _program_memory_target(program_memory_file, mem_name),
                    )

            # Export PYTHONPATH in the shell so the simulator child inherits it.
            pythonpath = env.get("PYTHONPATH", "")
            cmd = f"export PYTHONPATH='{pythonpath}' && make COCOTB_TEST_MODULES='{self.python_test_module}' TOPLEVEL={self.hdl_toplevel_module}"

            # Never accept a preceding run's report when make skips execution.
            # Sweep workers already assign distinct result paths.
            report_path = Path(env.get("COCOTB_RESULTS_FILE", "results.xml"))
            report_path.unlink(missing_ok=True)

            if capture_output:
                result = subprocess.run(
                    ["bash", "-c", cmd],
                    capture_output=True,
                    text=True,
                    env=env,
                    check=check,
                )
            else:
                result = subprocess.run(
                    ["bash", "-c", cmd],
                    env=env,
                    check=check,
                    text=True,
                    stdout=None,  # Stream to terminal.
                    stderr=None,  # Stream to terminal.
                )

            # Record the build markers only after a successful run, so a failed
            # compile is never recorded as built.
            if result.returncode == 0:
                try:
                    report = ElementTree.parse(report_path)
                except (OSError, ElementTree.ParseError) as exc:
                    raise RuntimeError(
                        f"Simulator returned success without a valid fresh report: {report_path}"
                    ) from exc
                cases = report.findall(".//testcase")
                if not cases or any(
                    case.find("failure") is not None or case.find("error") is not None
                    for case in cases
                ):
                    raise RuntimeError(
                        f"Simulator report has no tests or contains failures: {report_path}"
                    )
                self._update_verilator_toplevel_marker(sim_build_dir)

            return result

        finally:
            # Sweep workers share the symlinks with their siblings; the sweep
            # parent removes them after the whole pool drains.
            if self.app_name and not self.skip_app_compile:
                for mem_name in PROGRAM_MEMORY_FILENAMES:
                    mem_path = Path(mem_name)
                    if mem_path.exists() or mem_path.is_symlink():
                        mem_path.unlink()
            os.chdir(original_dir)


# =============================================================================
# Helper function for running tests
# =============================================================================


def run_test(test_name: str, capsys: Any | None = None) -> None:
    """Run a test with Verilator.

    Args:
        test_name: Name of the test from TEST_REGISTRY
        capsys: Optional pytest capsys fixture for output control

    Raises:
        pytest.fail: If the test fails
        KeyError: If test_name is not in TEST_REGISTRY
    """
    os.environ["SIM"] = "verilator"
    config = TEST_REGISTRY[test_name]
    runner = CocotbRunner.from_config(config)

    if capsys is not None:
        with capsys.disabled():
            print(f"\nRunning {test_name}...")
            result = runner.run_simulation(check=False, capture_output=False)
    else:
        print(f"\nRunning {test_name}...")
        result = runner.run_simulation(check=False, capture_output=False)

    if runner.check_for_failures(result):
        pytest.fail(f"Cocotb test {test_name} failed. Check output for details.")


# =============================================================================
# Pytest Test Classes
# =============================================================================


@pytest.mark.cocotb
class TestRealPrograms:
    """Real programs compiled and run on the frost toplevel."""

    @pytest.mark.slow
    @pytest.mark.parametrize("test_name", REAL_PROGRAM_TEST_PARAMS)
    def test_real_program(self, test_name: str, capsys: Any) -> None:
        """Run a real program test through cocotb.

        Pytest generates test IDs like:
            test_real_program[hello_world]
            test_real_program[coremark]
        """
        mem_config = os.environ.get("FROST_COCOTB_MEM_CONFIG", "bram")
        if mem_config == "ddr" and test_name in DDR_TIER_EXCLUDE:
            pytest.skip(
                f"{test_name} does not run in the ddr tier (fetch fuzzer or DDR probe)"
            )
        run_test(test_name, capsys)


@pytest.mark.cocotb
class TestUnitTests:
    """Unit benches: registry entries without an application."""

    @pytest.mark.slow
    @pytest.mark.parametrize("test_name", UNIT_TEST_PARAMS)
    def test_unit(self, test_name: str, capsys: Any) -> None:
        """Run one unit bench through cocotb."""
        run_test(test_name, capsys)


# =============================================================================
# Seed Sweep Support
# =============================================================================


def _run_single_seed(
    test_name: str,
    seed: int,
    testcase: str | None,
    temp_dir: str,
) -> tuple[int, bool, str]:
    """Run one seed in a separate process.

    Args:
        test_name: Name of the test from TEST_REGISTRY
        seed: Random seed for this run
        testcase: Optional specific test case to run
        temp_dir: Temporary directory for build artifacts

    Returns:
        Tuple of (seed, passed, error_message)
    """
    os.environ["SIM"] = "verilator"
    os.environ["COCOTB_RANDOM_SEED"] = str(seed)
    os.environ["SIM_BUILD"] = os.path.join(temp_dir, f"sim_build_{seed}")
    # Use a per-worker results file; the default results.xml in the shared
    # working directory lets concurrent workers overwrite each other's results.
    os.environ["COCOTB_RESULTS_FILE"] = os.path.join(temp_dir, f"results_{seed}.xml")

    if testcase:
        os.environ["COCOTB_TEST_FILTER"] = f"{testcase}$"

    config = TEST_REGISTRY[test_name]
    runner = CocotbRunner.from_config(config)
    # The sweep parent compiled the app (if any) once before the pool;
    # workers must not clean+recompile the shared sw/apps/<app> build or
    # unlink the shared tests/sw*.mem symlinks mid-sweep.
    runner.skip_app_compile = True

    try:
        result = runner.run_simulation(check=False, capture_output=True)
        passed = not runner.check_for_failures(result)
        error_msg = ""
        if not passed:
            combined = (result.stdout or "") + (result.stderr or "")
            lines = combined.strip().split("\n")
            error_msg = "\n".join(lines[-20:]) if lines else "Unknown error"
        return (seed, passed, error_msg)
    except Exception as e:
        return (seed, False, str(e))


def run_seed_sweep(
    test_name: str,
    num_seeds: int,
    testcase: str | None = None,
    max_workers: int | None = None,
) -> dict[str, Any]:
    """Run seeds in parallel and return the results summary.

    Each worker has its own SIM_BUILD and COCOTB_RESULTS_FILE. Compile the app
    once and share its sw*.mem links read-only to avoid build and unlink races.

    Args:
        test_name: Entry in TEST_REGISTRY.
        num_seeds: Number of seeds to run.
        testcase: Optional cocotb test function.
        max_workers: Parallel worker limit; defaults to num_seeds capped at
            the CPU count.
    """
    seeds = [random.randint(0, 2**31 - 1) for _ in range(num_seeds)]

    print(f"\n{'=' * 60}")
    print(f"Seed Sweep: Running {num_seeds} simulations in parallel")
    print(f"Test: {test_name}")
    print(f"Seeds: {seeds}")
    print(f"{'=' * 60}\n")

    # Prepare shared app images and links before any worker can read them.
    parent_runner = CocotbRunner.from_config(TEST_REGISTRY[test_name])
    # from_config applies the entry's extra_env to os.environ; the workers
    # inherit it, and the finally below restores it once the pool is done.
    try:
        if parent_runner.app_name:
            if not parent_runner._compile_app():
                raise RuntimeError(
                    f"Failed to compile application: {parent_runner.app_name}"
                )
            program_memory_file = parent_runner._get_program_memory_file()
            if program_memory_file:
                for mem_name in PROGRAM_MEMORY_FILENAMES:
                    CocotbRunner._ensure_symlink(
                        parent_runner.test_directory / mem_name,
                        _program_memory_target(program_memory_file, mem_name),
                    )

        results: dict[int, tuple[bool, str]] = {}
        workers = max_workers if max_workers else min(num_seeds, os.cpu_count() or 4)

        with tempfile.TemporaryDirectory(prefix="frost_seed_sweep_") as temp_dir:
            with ProcessPoolExecutor(max_workers=workers) as executor:
                futures = {
                    executor.submit(
                        _run_single_seed, test_name, seed, testcase, temp_dir
                    ): seed
                    for seed in seeds
                }

                for future in as_completed(futures):
                    seed = futures[future]
                    try:
                        ret_seed, passed, error_msg = future.result()
                        results[ret_seed] = (passed, error_msg)
                        status = "PASSED" if passed else "FAILED"
                        print(f"  Seed {ret_seed}: {status}")
                    except Exception as e:
                        results[seed] = (False, str(e))
                        print(f"  Seed {seed}: FAILED (exception: {e})")

        # The workers shared the parent-created symlinks; clean up after the pool.
        if parent_runner.app_name:
            for mem_name in PROGRAM_MEMORY_FILENAMES:
                mem_path = parent_runner.test_directory / mem_name
                if mem_path.exists() or mem_path.is_symlink():
                    mem_path.unlink()
    finally:
        parent_runner.restore_environment()

    passed_seeds = [s for s, (p, _) in results.items() if p]
    failed_seeds = [s for s, (p, _) in results.items() if not p]

    print(f"\n{'=' * 60}")
    print("SEED SWEEP REPORT")
    print(f"{'=' * 60}")
    print(f"Total runs: {num_seeds}")
    print(f"Passed: {len(passed_seeds)}")
    print(f"Failed: {len(failed_seeds)}")
    print()

    if passed_seeds:
        print(f"Passing seeds: {sorted(passed_seeds)}")
    if failed_seeds:
        print(f"Failing seeds: {sorted(failed_seeds)}")
        print("\nFailure details (tail of each):")
        for seed in sorted(failed_seeds):
            _, error_msg = results[seed]
            tail_lines = [
                line for line in error_msg.strip().splitlines() if line.strip()
            ][-3:]
            print(f"  Seed {seed}:")
            for line in tail_lines:
                print(f"    {line}")
        testcase_arg = f" --testcase {testcase}" if testcase else ""
        print("\nTo reproduce a failure, run:")
        for seed in sorted(failed_seeds):
            print(
                f"  ./test_run_cocotb.py {test_name}{testcase_arg} --random-seed={seed}"
            )

    print(f"{'=' * 60}\n")

    return {
        "total": num_seeds,
        "passed": len(passed_seeds),
        "failed": len(failed_seeds),
        "passed_seeds": passed_seeds,
        "failed_seeds": failed_seeds,
        "details": results,
    }


# =============================================================================
# Command-line Interface
# =============================================================================


def main() -> None:
    """Run cocotb simulation from command line."""
    import argparse

    test_choices = sorted(TEST_REGISTRY.keys())

    parser = argparse.ArgumentParser(
        description="Run cocotb simulations for FROST",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s hello_world              # Run Hello World
  %(prog)s isa_test                 # Run ISA checks
  %(prog)s --list-tests             # List available tests and exit

Seed sweeps run simulations in parallel and report each seed's status.

Available tests:
"""
        + "\n".join(
            f"  {name:20} - {cfg.description}"
            for name, cfg in sorted(TEST_REGISTRY.items())
        ),
    )
    parser.add_argument(
        "test",
        nargs="?",
        choices=test_choices,
        help="Test to run (required unless --list-tests is used)",
    )
    parser.add_argument(
        "--list-tests",
        action="store_true",
        help="List available tests and exit",
    )
    parser.add_argument(
        "--testcase",
        default=None,
        help="Test-name regex matched at the end (default: COCOTB_TEST_FILTER or all "
        "tests)",
    )
    parser.add_argument(
        "--random-seed",
        default=None,
        help="Random seed (default: COCOTB_RANDOM_SEED or a cocotb-selected seed)",
    )
    parser.add_argument(
        "--seed-sweep",
        type=int,
        default=None,
        metavar="N",
        help="Run N randomly seeded simulations in parallel (default: one run)",
    )
    parser.add_argument(
        "--max-workers",
        type=int,
        default=None,
        metavar="W",
        help="Maximum seed-sweep workers (default: min(N, CPU count or 4))",
    )

    args = parser.parse_args()

    if args.list_tests:
        print("Available cocotb tests (from TEST_REGISTRY):")
        for name, cfg in sorted(TEST_REGISTRY.items()):
            print(f"  {name:20} - {cfg.description}")
        sys.exit(0)

    if args.test is None:
        parser.error("the following arguments are required: test")

    if args.seed_sweep:
        if args.seed_sweep < 1:
            print("Error: --seed-sweep requires a positive integer")
            sys.exit(1)
        if args.random_seed:
            print("Error: --seed-sweep and --random-seed are mutually exclusive")
            sys.exit(1)
        results = run_seed_sweep(
            test_name=args.test,
            num_seeds=args.seed_sweep,
            testcase=args.testcase,
            max_workers=args.max_workers,
        )

        if results["failed"] > 0:
            sys.exit(1)
        sys.exit(0)

    os.environ["SIM"] = "verilator"
    if args.testcase:
        # COCOTB_TEST_FILTER is a regex. Anchor only at the end: cocotb may
        # prefix the name with the module path.
        os.environ["COCOTB_TEST_FILTER"] = f"{args.testcase}$"
    if args.random_seed:
        os.environ["COCOTB_RANDOM_SEED"] = args.random_seed

    config = TEST_REGISTRY[args.test]
    runner = CocotbRunner.from_config(config)

    result = runner.run_simulation(check=False, capture_output=False)

    if runner.check_for_failures(result):
        print("\nSimulation FAILED! Check output above for details.")
        sys.exit(1)
    else:
        print("\nSimulation completed successfully!")


if __name__ == "__main__":
    main()
