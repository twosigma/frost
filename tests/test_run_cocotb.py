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

"""Run cocotb simulations directly or through pytest.

Standalone:
    ./test_run_cocotb.py hello_world
    ./test_run_cocotb.py reorder_buffer
    ./test_run_cocotb.py --list-tests

Pytest (all tests):
    pytest ./test_run_cocotb.py

Pytest (real program tests only):
    pytest ./test_run_cocotb.py -k programs

Pytest (tomasulo unit tests only):
    pytest ./test_run_cocotb.py -k unit
"""

import os
import random
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from collections.abc import Mapping

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


COREMARK_PRO_TESTS = {
    program.app_name: CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name=program.app_name,
        description=program.description,
        # All nine workloads run CRC-verified minimal-preset simulations.
        # They are also all hardware-supported: the DDR-backed heap and
        # calibrated hardware_iterations cover the larger datasets
        # (loops/radix2/zip included); sim keeps the small verified presets.
    )
    for program in COREMARK_PRO_PROGRAMS
}

# Registry of all available tests - single source of truth
# Maps test name to its configuration
TEST_REGISTRY: dict[str, CocotbRunConfig] = {
    # Real program tests - all use same module/toplevel, differ only in app
    "branch_pred_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="branch_pred_test",
        description="Branch prediction test",
    ),
    "c_ext_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="c_ext_test",
        description="C extension test",
    ),
    "cf_ext_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="cf_ext_test",
        description="Compressed double-precision FP (Zcd) load/store test",
    ),
    "call_stress": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="call_stress",
        description="Call stress test",
    ),
    "coremark": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="coremark",
        description="Coremark benchmark",
    ),
    **COREMARK_PRO_TESTS,
    "ddr_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ddr_test",
        description="Cached-region (DDR) tier store/load test through the cache hierarchy",
    ),
    "ddr_exec_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ddr_exec_test",
        description="Execute-from-DDR test (.ddr_text through the fetch provider + L1I)",
    ),
    "ddr_smc_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ddr_smc_test",
        description="Self-modifying code test (stores + fence.i + execute, full sync chain)",
    ),
    "smc_fencei_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="smc_fencei_test",
        description="Hardened SMC/fence.i reproducer (gap sweep, warm/cold L1D, write-miss, tight loop)",
    ),
    "ddr_heap_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ddr_heap_test",
        description="DDR heap capacity test (multi-MB malloc from the cached region)",
    ),
    "ddr_mlp_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ddr_mlp_test",
        description=(
            "Memory-level-parallelism probe: independent cold loads, a pointer chase and a "
            "store burst over the cached region; requires overlapped L1D misses (counters). "
            "4 KiB L1D, no L2, so every miss takes the DDR round trip"
        ),
        verilator_extra_args=("-GL1_CACHE_BYTES=4096", "-GCACHED_HAS_L2=0"),
    ),
    "csr_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="csr_test",
        description="CSR test",
    ),
    "umode_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="umode_test",
        description="U-mode (User privilege) directed test incl. mcounteren counter gating",
    ),
    "pma_fault_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="pma_fault_test",
        description=(
            "PMA access-fault directed test (Phase 3 M2): out-of-map "
            "fetch/load/store/AMO/LR raise causes 1/5/7 with exact mepc/mtval "
            "(replacing the pre-M2 silent aliasing); access outranks misalign; "
            "in-map behavior unchanged"
        ),
    ),
    "vm_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="vm_test",
        description=(
            "Sv39 data-translation directed test (Phase 3 M4): MPRV-window "
            "translated accesses — 4K/2M/1G mappings, the R/W/X/U×SUM/MXR "
            "permission matrix, Svade A/D traps, malformed PTEs, walker PMA "
            "refusals, non-canonical VAs, sfence.vma visibility, satp-switch "
            "retargeting, translated LR/SC/AMO faults, a device page, and the "
            "Bare-domain misaligned-SC/AMO cause fixes; exact cause/mtval "
            "checks throughout"
        ),
    ),
    "itlb_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="itlb_test",
        description=(
            "Sv39 fetch-translation directed test (Phase 3 M5): S/U-mode "
            "execution through non-identity 4K pages and identity superpages, "
            "page-crossing windows and page-straddling instructions (hit and "
            "fault, exact epc/tval), X/U/A permission faults, fetch PMA on the "
            "translated PA, walker refusals, non-canonical targets, ITLB "
            "replacement, sfence.vma and satp-switch retargeting"
        ),
    ),
    "debug_test": CocotbRunConfig(
        python_test_module="cocotb_tests.debug.test_debug",
        hdl_toplevel_module="frost",
        app_name="debug_target",
        description=(
            "RISC-V debug module directed test (Phase 3 M3): a cocotb JTAG "
            "bit-bang debugger drives the DTM/DM through halt, dcsr/dpc, "
            "abstract GPR access, progbuf CSR/memory access (BRAM, MMIO, DDR), "
            "abstractauto, progbuf exceptions, software breakpoints in BRAM "
            "code (32-bit and c.ebreak via the store mirror), single step incl. "
            "over an ecall, halt in U-mode with dcsr.prv round-trip, halt in "
            "wfi, resume, and ndmreset/havereset against debug_target"
        ),
    ),
    "debug_openocd_test": CocotbRunConfig(
        python_test_module="cocotb_tests.debug.test_debug_openocd",
        hdl_toplevel_module="frost",
        app_name="debug_target",
        description=(
            "OpenOCD in the loop (Phase 3 M3): the bench serves OpenOCD's "
            "remote_bitbang protocol and a real openocd examines, halts, reads "
            "and writes registers and memory, sets a breakpoint, steps and "
            "resumes debug_target; skips when openocd is not installed"
        ),
    ),
    "satp_drain_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="satp_drain_test",
        description=(
            "Committed-store drain across the D10 translation flush: a cached-"
            "DDR store immediately before a satp / translation-relevant mstatus "
            "write must survive the post-commit flush (the page-table-setup "
            "store-loss regression)"
        ),
    ),
    "plic_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="plic_test",
        description=(
            "PLIC directed test: register WARL widths, level-gateway claim/"
            "complete/re-raise/spurious, threshold masking, priority-0, both "
            "contexts' EIP readbacks, and an M-mode take that claims and "
            "completes in the handler (ns16550 THRE as the level source)"
        ),
    ),
    "sstc_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="sstc_test",
        description=(
            "Sstc directed test: menvcfg.STCE WARL, stimecmp M access, the "
            "registered compare driving STIP with the software bit dormant, "
            "the S-mode STCE=0 illegal gate, and a delegated S timer take "
            "through stimecmp"
        ),
    ),
    "ns16550_irq_console_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ns16550_irq_console_test",
        description=(
            "Interrupt-driven ns16550 console: every byte of the message is "
            "written from the external-interrupt handler through a PLIC "
            "claim/complete per THRE re-raise; main only arms and waits"
        ),
    ),
    "ad_fault_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ad_fault_test",
        description=(
            "A/D-transition faults: rewriting a live PTE to A=0/D=0 must make "
            "the next access fault (the read-only-walker contract the demand "
            "pager relies on), plus a translated 4 KiB demand copy verified "
            "physically against its backing"
        ),
    ),
    "smode_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="smode_test",
        description=(
            "S-mode directed test: delegation matrix (medeleg/mideleg), sret "
            "round-trips, TSR/TVM/TW gates, sstatus/sie/sip views, scounteren "
            "chain, unimplemented-CSR traps, delegated interrupts with sret resume"
        ),
    ),
    "csr_rmw_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="csr_rmw_test",
        description=(
            "CSR read-modify-write directed test "
            "(csrrw/csrrs/csrrc; kernel trap path; mperfctl bank control)"
        ),
    ),
    "wfi_mepc_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="wfi_mepc_test",
        description="Timer-interrupt-at-WFI mepc directed test (empty-ROB interrupt resume PC)",
    ),
    "wfi_drain_mepc_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="wfi_drain_mepc_test",
        description="Drain-gated WFI mepc directed test (timer IRQ at WFI with a draining DDR store)",
    ),
    "drain_trapframe_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="drain_trapframe_test",
        description="Trap-frame store-visibility under L1D eviction (Bug B relocated to pt_regs s2)",
        # Genesys2-faithful shape: no L2 (L1 -> DDR direct, where a cold write-back
        # actually drains) + high DDR latency, so the save-store / eviction race is
        # not masked. The default (L2 on, latency 30) gives a false PASS.
        verilator_extra_args=("-GCACHED_HAS_L2=0", "-GDDR_MODEL_LATENCY=70"),
    ),
    "mret_timer_resume_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="mret_timer_resume_test",
        description="MRET-to-U + pending-timer mepc directed test (stale interrupt resume PC)",
    ),
    "restore_window_stress": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="restore_window_stress",
        description="M-mode ret_from_exception restore-window stress (phase-swept; kernel-patch retirement evidence)",
        # Genesys2-faithful shape (L1 -> DDR direct + high latency) so the
        # window's SC/loads miss cold and the committed-store drain that the
        # June 2026 flaky boot depended on actually happens.
        verilator_extra_args=("-GCACHED_HAS_L2=0", "-GDDR_MODEL_LATENCY=70"),
    ),
    "mtimer_stress": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="mtimer_stress",
        description="M-mode machine-timer + MRET deadlock stress (phase-swept; flaky-hang repro)",
    ),
    "mret_drain_deadlock": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="mret_drain_deadlock",
        description="MRET-vs-draining-cached-store deadlock (one-shot o_mret_start; deterministic hang repro)",
        # Genesys2 cache shape (L1 -> DDR direct), where the bug manifests on
        # hardware and where a cold cached-store write-back actually drains in sim
        # (the L2-enabled shape leaves the cold tier undrained, masking the race).
        verilator_extra_args=("-GCACHED_HAS_L2=0",),
    ),
    "wfi_lost_tick": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="wfi_lost_tick",
        description="WFI-idle + MIE-toggle + CLINT-rearm lost-timer-tick repro (deferred-eligibility; frozen jiffies)",
    ),
    "irq_mie_window": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="irq_mie_window",
        description="Short-MIE-window lost-interrupt repro (registered interrupt_pending erased by adjacent MIE clear)",
    ),
    "ns16550_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ns16550_test",
        description="ns16550a UART face directed test (Linux glue)",
    ),
    "clint_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="clint_test",
        description="SiFive CLINT alias directed test (Linux glue)",
    ),
    "jal_target_seam": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="jal_target_seam",
        description=(
            "fetch-seam directed repro: 4-byte jal entered as a taken-branch "
            "target at dword offset 4 / line offset 0x2c (the Linux "
            "of_core_init call-skip bug, XLEN-independent -- stale "
            "pending-saved BTB metadata replayed onto the re-fetched jal made "
            "the ROB see a correctly predicted jal while the redirect was "
            "lost); run with FROST_COCOTB_MEM_CONFIG=ddr for the "
            "kernel-faithful variable-latency L1I fetch path (bram never "
            "arms the pending walk and passes)"
        ),
        verilator_extra_args=("-GL1I_CACHE_BYTES=131072", "-GCACHED_HAS_L2=0"),
    ),
    "writecount_probe": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="writecount_probe",
        description=(
            "ETXTBSY directed probe: replays the Linux deny_write_access "
            "lr.w/bgtz/sc.w.rl scene (exec1 count 0->-1, exec2 count -1->-2) "
            "word-exact on both dword lanes with a positive neighbor pattern, "
            "plus amoadd.w allow path and line-pressure variants; caught the "
            "rv64 LR.W zero-extension hole (mem_signed excluded OPC_AMO, so "
            "negative counts read positive and exec of a running inode "
            "failed Text-file-busy on hardware); run with "
            "FROST_COCOTB_MEM_CONFIG=ddr for the kernel-faithful cached tier"
        ),
        verilator_extra_args=("-GL1I_CACHE_BYTES=131072", "-GCACHED_HAS_L2=0"),
    ),
    "mem_divergence_probe": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="mem_divergence_probe",
        description=(
            "cached-DDR cold-vs-warm read divergence probe (rv64 Linux "
            "hardware bring-up debug 2026-08-04): evict/refill sweeps over "
            "32/64-bit reads at both dword halves plus store-forward "
            "interleavings; a FAIL is the hunted reproduction"
        ),
        include_in_pytest=False,
        extra_env=(("EXTRA_CFLAGS", "-DN_ROUNDS=8"),),
        verilator_extra_args=("-GCACHED_HAS_L2=0",),
    ),
    "bram_reload": CocotbRunConfig(
        python_test_module="cocotb_tests.test_bram_reload",
        hdl_toplevel_module="frost",
        app_name="hello_world",
        description=(
            "JTAG/port-A image reload path: power-on boot, clobber via the "
            "programming port (must not boot), full reload (must boot) -- "
            "mirrors fpga/load_software/file_to_bram.tcl; the ONLY sim "
            "coverage of the loader write path"
        ),
    ),
    "linux_boot": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="linux_boot",
        description="No-MMU Linux boot (kernel Image in DDR)",
        include_in_pytest=False,
    ),
    # Same boot image, but 128 KiB L1I (the genesys2 HW config the handoff says
    # wedges at SLUB). Pair with CACHED_HAS_L2=0 to match genesys2. Debug only.
    "linux_boot_128k": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="linux_boot",
        description="No-MMU Linux boot with 128 KiB L1I (genesys2 wedge-repro config)",
        include_in_pytest=False,
        verilator_extra_args=("-GL1I_CACHE_BYTES=131072", "-GCACHED_HAS_L2=0"),
    ),
    "linux_irq_ddr_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="linux_irq_ddr_test",
        description="Linux-like machine-timer IRQ path with DDR code/data/stack",
    ),
    "amo_irq_torture": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="amo_irq_torture",
        description=(
            "Timer IRQ swept across cached-DDR AMO bursts; counts every atomic "
            "side effect (AMO-vs-interrupt-flush orphaned-write regression). "
            "Sim runs need EXTRA_CFLAGS=-DAMO_TORTURE_ITERS=<=384 (default "
            "24000 is hardware-scale); the bench budgets 6M cycles/run "
            "(COCOTB_AMO_TORTURE_MAX_CYCLES overrides). CI runs the pinned "
            "amo_irq_torture_sim variant below"
        ),
        include_in_pytest=False,
    ),
    "tick_torture": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="tick_torture",
        description=(
            "Linux-faithful CLINT re-arm under DDR thrash with readback verify "
            "and lost-tick watchdog. Hardware-scale by default (262144 ticks "
            "~ 2.1B cycles); sim runs need EXTRA_CFLAGS='-DTARGET_TICKS=<small>' "
            "(the bench's dedicated tick budget applies, "
            "COCOTB_TICK_TORTURE_MAX_CYCLES overrides). CI runs the pinned "
            "tick_torture_sim variant below"
        ),
        include_in_pytest=False,
    ),
    "amo_irq_torture_jitter": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="amo_irq_torture",
        description=(
            "amo_irq_torture with per-transaction DDR-latency jitter "
            "(decorrelates completion timing like real DDR refresh, the "
            "regime that exposed the interrupt-orphaned AMO write). Same "
            "sim knobs as amo_irq_torture"
        ),
        include_in_pytest=False,
        verilator_extra_args=("-GDDR_MODEL_LATENCY_JITTER=19",),
    ),
    # Pinned sim-scale variants of the two hardware-scale torture apps, so the
    # soak classes (CLINT re-arm / AMO-vs-IRQ flush) run in CI instead of only
    # by hand. extra_env stomps EXTRA_CFLAGS deliberately: these names ARE the
    # fixed configurations (use the base entries above for custom scales), and
    # the bench's per-app budgets keyed on app_name apply to them unchanged.
    "amo_irq_torture_sim": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="amo_irq_torture",
        description=(
            "CI-scale amo_irq_torture: ITERS=256 (~2.61M cycles) against the "
            "bench's 6M amo budget — the 2026-07-10-validated configuration"
        ),
        extra_env=(("EXTRA_CFLAGS", "-DAMO_TORTURE_ITERS=256"),),
    ),
    "tick_torture_sim": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="tick_torture",
        description=(
            "CI-scale tick_torture: TARGET_TICKS=64 with a 256 KiB workset "
            "(still 2x the 128 KiB L1, but the default 2 MiB workset's "
            "crt0 .bss zeroing alone is ~10M cycles) against the bench's "
            "dedicated tick budget (COCOTB_TICK_TORTURE_MAX_CYCLES overrides)"
        ),
        extra_env=(("EXTRA_CFLAGS", "-DTARGET_TICKS=64 -DWORKSET_WORDS=65536u"),),
    ),
    "linux_irq_active_ddr_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="linux_irq_active_ddr_test",
        description="Linux-like active-code machine-timer IRQ path with DDR call/return traffic",
    ),
    "linux_clksrc_faithful": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="linux_clksrc_faithful",
        description="Faithful Linux clocksource-switch: enable-MTIE-then-arm, re-arming handler, bare-wfi idle, concurrent DDR",
    ),
    "trap_s2l_fwd": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="trap_s2l_fwd",
        description="handle_exception-pattern trap store->load forwarding repro (sd sp,8(tp); ld ,8(tp))",
    ),
    "linux_irq_stack_slot_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="linux_irq_stack_slot_test",
        description="Linux-like timer IRQ over a poisoned DDR callee return-address stack slot",
    ),
    "linux_irq_find_next_slot_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="linux_irq_find_next_slot_test",
        description="Linux _find_next_bit-shaped IRQ over a poisoned DDR return slot",
    ),
    "ddr_atomic_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ddr_atomic_test",
        description="Word-form atomics to the cached DDR region (LR/SC, AMO)",
        include_in_pytest=True,
    ),
    "pde_return_hazard": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="pde_return_hazard",
        description="pde_subdir_find epilogue return-value hazard reproducer",
        verilator_extra_args=("-GCACHED_HAS_L2=0",),
    ),
    "freertos_demo": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="freertos_demo",
        description=(
            "FreeRTOS demo (rv64 port from the M7 hardware bring-up: D13's "
            "deferral was retired by XLEN-splitting the port's context-switch "
            "assembly and types; the heap scales for XLEN-wide stack cells)"
        ),
    ),
    "fpu_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="fpu_test",
        description="FPU compliance test",
    ),
    "fpu_assembly_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="fpu_assembly_test",
        description="FPU assembly hazard tests",
    ),
    "hello_world": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="hello_world",
        description="Hello World program",
    ),
    "isa_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="isa_test",
        description="ISA compliance test suite",
    ),
    "memory_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="memory_test",
        description="Memory allocator test suite",
    ),
    "rv64_smoke": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="rv64_smoke",
        description="RV64 M2 smoke: W-ops/LD/SD/shamt6 minimum slice",
    ),
    "rv64_amo_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="rv64_amo_test",
        description=(
            "RV64 A-extension directed test (M6): doubleword AMOs with "
            "old-value AND memory checks at full 64-bit patterns, LR.D/SC.D "
            "success + no-reservation-fail paths, and AMOADD.W window "
            "semantics on a dword cell"
        ),
    ),
    "packet_parser": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="packet_parser",
        description="Packet parser test",
    ),
    "print_clock_speed": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="print_clock_speed",
        description="Print clock speed test",
    ),
    "spanning_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="spanning_test",
        description="Spanning instruction test",
    ),
    "sprintf_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="sprintf_test",
        description="sprintf/snprintf formatting test suite",
    ),
    "strings_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="strings_test",
        description="String library test suite",
    ),
    "ras_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ras_test",
        description="Return Address Stack (RAS) test suite",
    ),
    "ras_stress_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="ras_stress_test",
        description="RAS stress test (calls, branches, and function pointers)",
    ),
    "tomasulo_test": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="tomasulo_test",
        description="Tomasulo correctness tests (hazards, OOO, register renaming)",
    ),
    "tomasulo_perf": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="tomasulo_perf",
        description="Tomasulo performance measurement (IPC benchmarks)",
    ),
    "uart_echo": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="uart_echo",
        description="UART RX echo demo (driven via cocotb UART input)",
    ),
    # Fetch-latency fuzz: the same real programs with the simulation-only
    # variable-latency fetch provider (random i_instr_valid gaps), proving the
    # front end's fetch-invalid machinery before an I-cache sits behind it.
    # Grouped adjacently so the shared -G build is reused across all four.
    "hello_world_fetch_fuzz": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="hello_world",
        description="hello_world under randomized fetch-latency fuzz",
        verilator_extra_args=("-GFETCH_VALID_FUZZ=1",),
    ),
    "branch_pred_test_fetch_fuzz": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="branch_pred_test",
        description="Branch-prediction stress under randomized fetch-latency fuzz",
        verilator_extra_args=("-GFETCH_VALID_FUZZ=1",),
    ),
    "c_ext_test_fetch_fuzz": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="c_ext_test",
        description="C-extension alignment stress under randomized fetch-latency fuzz",
        verilator_extra_args=("-GFETCH_VALID_FUZZ=1",),
    ),
    "call_stress_fetch_fuzz": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="call_stress",
        description="RAS call/return stress under randomized fetch-latency fuzz",
        verilator_extra_args=("-GFETCH_VALID_FUZZ=1",),
    ),
    "itlb_test_fetch_fuzz": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="itlb_test",
        description="Translated fetch (ITLB misses, page crossings, fault windows) under fetch-latency fuzz",
        verilator_extra_args=("-GFETCH_VALID_FUZZ=1",),
    ),
    "fetch_lead_repro": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="fetch_lead_repro",
        description=(
            "Fetch-lead repro: a call into a cold cached line whose first bundle "
            "advances by 6 and is followed by a 32-bit instruction at the served "
            "window's last upper halfword (the second half lives in the next word)"
        ),
    ),
    "fetch_stall_repro": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="fetch_stall_repro",
        description="Directed 32-bit-insn PC+2 mis-step repro (no fuzz; sanity = PASS)",
    ),
    "fetch_stall_repro_128k": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="fetch_stall_repro",
        description="Directed PC+2 mis-step repro, cached .ddr_text, 128KiB L1I (genesys2)",
        verilator_extra_args=("-GL1I_CACHE_BYTES=131072",),
    ),
    "window_skip_repro": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="window_skip_repro",
        description=(
            "Directed 'skipped fall-through fetch window' repro (genesys2 rv64 "
            "coremark_pro_zip / zlib longest_match): a trained-taken loop-back "
            "branch resolves not-taken on exit and early recovery redirects to "
            "the fall-through; the front end skips the aligned 8-byte "
            "fall-through window (the callee-saved restores) and runs the next "
            "window (sp-pop + ret), leaving s0/s1 STALE. Every victim's window "
            "layout is objdump-verified (bltu at its window+4, restores in one "
            "8B window, addi16sp+ret in the next). v2 subtests: A/B/C fast BRAM "
            "/ cached-DDR-latency / divu-backpressure; D/E loop-back TARGET at "
            "window+4 and window+2 (rvc head); F a 32-bit op spanning a window "
            "boundary (instruction-buffer covers arm); G the "
            "longest_match reload tail + epilogue lifted byte-for-byte. "
            "Normally <<PASS>>; a canary mismatch or the if_stage "
            "p_bram_served_window_covers_pc_reg assertion is the reproduction."
        ),
        extra_env=(("COCOTB_MAX_CYCLES", "4000000"),),
    ),
    "window_skip_repro_g2shape": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="window_skip_repro",
        description=(
            "window_skip_repro at the Genesys2 cache shape (no L2, 128 KiB "
            "L1I) — the configuration where the hardware failure reproduced; "
            "sweep DDR_MODEL_LATENCY externally to jitter branch-resolution "
            "timing"
        ),
        include_in_pytest=False,
        extra_env=(("COCOTB_MAX_CYCLES", "4000000"),),
        verilator_extra_args=("-GL1I_CACHE_BYTES=131072", "-GCACHED_HAS_L2=0"),
    ),
    "window_skip_repro_fetch_fuzz": CocotbRunConfig(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name="window_skip_repro",
        description=(
            "window_skip_repro under randomized fetch-valid fuzz: jitters the "
            "fetch window valid so redirects land on stall-replay corners the "
            "fixed-latency BRAM path never produces on its own"
        ),
        include_in_pytest=False,
        extra_env=(("COCOTB_MAX_CYCLES", "8000000"),),
        verilator_extra_args=("-GFETCH_VALID_FUZZ=1",),
    ),
    # Tomasulo unit tests
    "reorder_buffer": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.reorder_buffer.test_reorder_buffer",
        hdl_toplevel_module="reorder_buffer",
        description="Reorder Buffer unit tests (allocation, commit, flush, serialization)",
    ),
    "register_alias_table": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.register_alias_table.test_register_alias_table",
        hdl_toplevel_module="register_alias_table",
        description="Register Alias Table unit tests (rename, lookup, checkpoint, flush)",
    ),
    "rs_issue2_selector": CocotbRunConfig(
        python_test_module=(
            "cocotb_tests.tomasulo.reservation_station." "test_rs_issue2_selector"
        ),
        hdl_toplevel_module="rs_issue2_selector",
        description="Balanced INT-RS second-port selector reference equivalence",
    ),
    "reservation_station": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.reservation_station.test_reservation_station",
        hdl_toplevel_module="reservation_station",
        description=(
            "Reservation Station unit tests (deferred dispatch-CDB delivery "
            "and indexed repair)"
        ),
        verilator_extra_args=(
            "-GALLOC_INDEXED_REPAIR=1",
            "-GDISPATCH_REPAIR_BYPASS=0",
            "-GISSUE_REPAIR_BYPASS=0",
            "-GSPECULATIVE_DATA_WRITES=1",
            "-GBROADCAST_FREE_SOURCE_VALUES=1",
            "-GISSUE_CDB_TAG_SHADOW=1",
        ),
    ),
    "cdb_arbiter": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.cdb_arbiter.test_cdb_arbiter",
        hdl_toplevel_module="cdb_arbiter",
        description="CDB arbiter unit tests (priority, grant, propagation)",
    ),
    "fu_cdb_adapter": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.fu_cdb_adapter.test_fu_cdb_adapter",
        hdl_toplevel_module="fu_cdb_adapter",
        description="FU CDB adapter unit tests (holding register, pass-through, flush)",
    ),
    "fu_cdb_adapter_payload_no_refill": CocotbRunConfig(
        python_test_module=(
            "cocotb_tests.tomasulo.fu_cdb_adapter."
            "test_fu_cdb_adapter_payload_no_refill"
        ),
        hdl_toplevel_module="fu_cdb_adapter",
        description="FU CDB adapter simplified payload-write-enable contract",
        verilator_extra_args=("-GALLOW_GRANT_REFILL_PAYLOAD_WRITE=0",),
    ),
    "load_queue": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.load_queue.test_load_queue",
        hdl_toplevel_module="load_queue",
        description=(
            "Load queue unit tests (allocation, disambiguation, router-pending "
            "cancellation/debt, dependency cleanup, conservative dispatch "
            "back-pressure, memory, and CDB)"
        ),
    ),
    "store_queue": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.store_queue.test_store_queue",
        hdl_toplevel_module="store_queue",
        description="Store queue unit tests (allocation, forwarding, memory writes, flush)",
    ),
    "int_alu_shim": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.fu_shims.test_int_alu_shim",
        hdl_toplevel_module="int_alu_shim",
        description="Integer ALU shim unit tests (ADD, SUB, shifts, LUI, AUIPC, JAL, CSR)",
    ),
    "int_muldiv_shim": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.fu_shims.test_int_muldiv_shim",
        hdl_toplevel_module="int_muldiv_shim",
        description="Integer MUL/DIV shim unit tests (MUL, MULH, DIV, REM, flush)",
    ),
    "fp_add_shim": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.fu_shims.test_fp_add_shim",
        hdl_toplevel_module="fp_add_shim",
        description="FP add shim unit tests (FADD, FSUB, compare, classify, sgnj, convert)",
    ),
    "fp_mul_shim": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.fu_shims.test_fp_mul_shim",
        hdl_toplevel_module="fp_mul_shim",
        description=(
            "FP mul shim tests (FMUL/FMADD/FMSUB arithmetic; payload queues, "
            "collision, wraparound, back-pressure, flush)"
        ),
    ),
    "fp_div_shim": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.fu_shims.test_fp_div_shim",
        hdl_toplevel_module="fp_div_shim",
        description="FP div shim unit tests (FDIV, FSQRT, flush)",
    ),
    "dispatch": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.dispatch.test_dispatch",
        hdl_toplevel_module="dispatch",
        description="Dispatch unit tests (instruction classification, source resolution, stall, RS routing)",
    ),
    "branch_jump_unit": CocotbRunConfig(
        python_test_module="cocotb_tests.ex_stage.test_branch_jump_unit",
        hdl_toplevel_module="branch_jump_unit",
        description="EX-stage branch/jump resolution unit tests",
    ),
    "commit_actions": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.commit.test_commit_actions",
        hdl_toplevel_module="commit_actions",
        description="CPU OOO commit action tests (regfile writes, CSR writeback, instret)",
    ),
    "ex_comb_synthesizer": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.recovery.test_ex_comb_synthesizer",
        hdl_toplevel_module="ex_comb_synthesizer",
        description=(
            "CPU OOO from_ex_comb priority and independent BTB RMW candidate tests"
        ),
    ),
    "early_misprediction_recovery": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.recovery.test_early_misprediction_recovery",
        hdl_toplevel_module="early_misprediction_recovery",
        description="CPU OOO early misprediction recovery FSM tests",
    ),
    "misprediction_flush_controller": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.recovery.test_misprediction_flush_controller",
        hdl_toplevel_module="misprediction_flush_controller",
        description="CPU OOO misprediction flush controller tests",
    ),
    "branch_resolution": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.recovery.test_branch_resolution",
        hdl_toplevel_module="branch_resolution",
        description="CPU OOO branch resolution tests",
    ),
    "data_mem_request_router": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.memory.test_data_mem_request_router",
        hdl_toplevel_module="data_mem_request_router",
        description=(
            "CPU OOO data-memory router tests (arbitration, mandatory device staging, "
            "flush cancellation, drain ordering, and tier handshakes)"
        ),
    ),
    "trap_unit": CocotbRunConfig(
        python_test_module="cocotb_tests.control.test_trap_unit",
        hdl_toplevel_module="trap_unit",
        description="Trap unit tests (interrupt/MRET/exception and store-drain arbitration)",
    ),
    "packed_tag_uram_13": CocotbRunConfig(
        python_test_module="cocotb_tests.test_sdp_packed_tag_uram",
        hdl_toplevel_module="sdp_packed_tag_uram",
        description=(
            "Packed tag URAM: production 13-bit/four-slot hardware-storage geometry"
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
        description="Packed tag URAM: 13-bit/four-slot simulation bulk clear",
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
            "Packed tag URAM: 22-bit entries, two 27-bit slots/row, hardware branch"
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
        description="Cache hierarchy unit tests (L1 -> L2 -> DDR, X3 shape)",
        verilator_extra_args=("-GHAS_L2=1",),
    ),
    "frost_cache_l1_only": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_frost_cache",
        hdl_toplevel_module="frost_cache_test_harness",
        description="Cache hierarchy unit tests (L1 -> DDR, Genesys2 shape)",
        verilator_extra_args=("-GHAS_L2=0",),
    ),
    # Same functional suite, but with the sim-only fast maintenance path
    # (SIM_FAST_MAINT=1) enabled: proves invalidate-all / writeback-all stay
    # functionally identical when the fence.i fast path is active.
    "frost_cache_fast": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_frost_cache",
        hdl_toplevel_module="frost_cache_test_harness",
        description="Cache hierarchy unit tests, fast fence.i maintenance (L1 -> L2 -> DDR)",
        verilator_extra_args=("-GHAS_L2=1", "-GSIM_FAST_MAINT=1"),
    ),
    "frost_cache_l1_only_fast": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_frost_cache",
        hdl_toplevel_module="frost_cache_test_harness",
        description="Cache hierarchy unit tests, fast fence.i maintenance (L1 -> DDR)",
        verilator_extra_args=("-GHAS_L2=0", "-GSIM_FAST_MAINT=1"),
    ),
    # Same suites with the memory model completing transactions of different
    # ids out of issue order, which the tagged fabric must tolerate.
    "frost_cache_reorder": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_frost_cache",
        hdl_toplevel_module="frost_cache_test_harness",
        description="Cache hierarchy unit tests, out-of-order DDR completion (L1 -> L2 -> DDR)",
        verilator_extra_args=("-GHAS_L2=1", "-GMEM_REORDER=1"),
    ),
    # Multi-outstanding driver: pipelined hits, hit/miss-under-miss, merges,
    # waiters, index conflicts, writeback-then-fill, fence.i under misses.
    "frost_cache_concurrency": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_frost_cache_concurrency",
        hdl_toplevel_module="frost_cache_test_harness",
        description="Non-blocking cache concurrency tests (L1 -> L2 -> DDR, X3 shape)",
        verilator_extra_args=("-GHAS_L2=1",),
    ),
    "frost_cache_concurrency_l1_only": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_frost_cache_concurrency",
        hdl_toplevel_module="frost_cache_test_harness",
        description="Non-blocking cache concurrency tests (L1 -> DDR, Genesys2 shape)",
        verilator_extra_args=("-GHAS_L2=0",),
    ),
    "frost_cache_concurrency_reorder": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_frost_cache_concurrency",
        hdl_toplevel_module="frost_cache_test_harness",
        description="Non-blocking cache concurrency tests, out-of-order DDR completion (L1 -> L2 -> DDR)",
        verilator_extra_args=("-GHAS_L2=1", "-GMEM_REORDER=1"),
    ),
    "frost_cache_l1_only_reorder": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_frost_cache",
        hdl_toplevel_module="frost_cache_test_harness",
        description="Cache hierarchy unit tests, out-of-order DDR completion (L1 -> DDR)",
        verilator_extra_args=("-GHAS_L2=0", "-GMEM_REORDER=1"),
    ),
    # fence.i maintenance cycle-count measurement at the real L1 geometry
    # (128 KiB D / 16 KiB I). Two builds, slow (FPGA-path FSM) vs fast, so the
    # speedup is directly observable in the logs. Not part of the pytest sweep.
    "fence_speed_slow": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_fence_speed",
        hdl_toplevel_module="frost_cache_test_harness",
        description="fence.i maintenance cost, FPGA-path FSM (SIM_FAST_MAINT=0)",
        verilator_extra_args=(
            "-GHAS_L2=0",
            "-GL1_CACHE_BYTES=131072",
            "-GL1I_CACHE_BYTES=16384",
            "-GSIM_FAST_MAINT=0",
        ),
        include_in_pytest=False,
    ),
    "fence_speed_fast": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_fence_speed",
        hdl_toplevel_module="frost_cache_test_harness",
        description="fence.i maintenance cost, fast sim path (SIM_FAST_MAINT=1)",
        verilator_extra_args=(
            "-GHAS_L2=0",
            "-GL1_CACHE_BYTES=131072",
            "-GL1I_CACHE_BYTES=16384",
            "-GSIM_FAST_MAINT=1",
        ),
        include_in_pytest=False,
    ),
    "line_port_arbiter": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_line_port_arbiter",
        hdl_toplevel_module="line_port_arbiter_test_harness",
        description=(
            "Tagged N:1 line-port arbiter unit tests (priority, no grant lock, "
            "multiple outstanding per port, id-routed responses)"
        ),
    ),
    "line_port_arbiter_reorder": CocotbRunConfig(
        python_test_module="cocotb_tests.cache.test_line_port_arbiter",
        hdl_toplevel_module="line_port_arbiter_test_harness",
        description="Tagged line-port arbiter unit tests with out-of-order DDR completion",
        verilator_extra_args=("-GMEM_REORDER=1",),
    ),
    "imem_predecode_line": CocotbRunConfig(
        python_test_module="cocotb_tests.predecode.test_imem_predecode_line",
        hdl_toplevel_module="imem_predecode_line",
        description="Per-line predecode sideband cross-checked against the python generator",
    ),
    "imem_predecode_fast_replica": CocotbRunConfig(
        python_test_module="cocotb_tests.predecode.test_imem_predecode_fast_replica",
        hdl_toplevel_module="imem_predecode",
        description=(
            "Hot/cold IMEM banks plus pinned scalar overlay and registered slow fallback"
        ),
        verilator_extra_args=(
            "-GADDR_WIDTH=4",
            "-GPC_METADATA_OVERLAY_ADDR_WIDTH=2",
            "-GUSE_INIT_FILE=0",
        ),
    ),
    "low_bram_fetch_presenter": CocotbRunConfig(
        python_test_module="cocotb_tests.predecode.test_low_bram_fetch_presenter",
        hdl_toplevel_module="low_bram_fetch_presenter",
        description=(
            "Exact low-BRAM repeat, stall-safe publication, retarget, and PA resolution"
        ),
    ),
    "fetch_provider": CocotbRunConfig(
        python_test_module="cocotb_tests.predecode.test_fetch_provider",
        hdl_toplevel_module="fetch_provider",
        description="Fetch provider unit tests (quadrant steer, fetch buffer, fills, invalidate)",
    ),
    "frontend_validity_tracker": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.frontend.test_frontend_validity_tracker",
        hdl_toplevel_module="frontend_validity_tracker",
        description="CPU OOO frontend validity/control-flow tracker tests",
    ),
    "perf_counter_aggregator": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.perf.test_perf_counter_aggregator",
        hdl_toplevel_module="perf_counter_aggregator",
        description="CPU OOO performance-counter aggregator tests",
    ),
    "ooo_pipeline_control": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.pipeline_control.test_ooo_pipeline_control",
        hdl_toplevel_module="ooo_pipeline_control",
        description="CPU OOO pipeline-control tests",
    ),
    "ooo_register_files": CocotbRunConfig(
        python_test_module="cocotb_tests.cpu_ooo.register_files.test_ooo_register_files",
        hdl_toplevel_module="ooo_register_files",
        description="CPU OOO architectural register-files tests",
    ),
    "ras_detector": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.branch_prediction.test_ras_detector",
        hdl_toplevel_module="ras_detector",
        description="IF-stage RAS instruction detector tests",
    ),
    "return_address_stack": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.branch_prediction.test_return_address_stack",
        hdl_toplevel_module="return_address_stack",
        description="IF-stage return-address stack tests",
    ),
    "branch_predictor": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.branch_prediction.test_branch_predictor",
        hdl_toplevel_module="branch_predictor",
        description="IF-stage branch target buffer predictor tests",
    ),
    "direction_predictor": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.branch_prediction.test_direction_predictor",
        hdl_toplevel_module="direction_predictor",
        description="IF-stage branch direction predictor tests",
    ),
    "branch_prediction_controller": CocotbRunConfig(
        python_test_module=(
            "cocotb_tests.if_stage.branch_prediction."
            "test_branch_prediction_controller"
        ),
        hdl_toplevel_module="branch_prediction_controller",
        description="IF-stage branch prediction controller tests",
    ),
    "prediction_metadata_tracker": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.branch_prediction.test_prediction_metadata_tracker",
        hdl_toplevel_module="prediction_metadata_tracker",
        description="IF-stage prediction metadata tracker tests",
    ),
    "control_flow_tracker": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.test_control_flow_tracker",
        hdl_toplevel_module="control_flow_tracker",
        description="IF-stage control-flow holdoff tracker tests",
    ),
    "pc_increment_calculator": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.test_pc_increment_calculator",
        hdl_toplevel_module="pc_increment_calculator",
        description="IF-stage PC increment calculator tests",
    ),
    "pc_controller": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.test_pc_controller",
        hdl_toplevel_module="pc_controller",
        description="IF-stage PC controller tests",
    ),
    "instruction_aligner": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.test_instruction_aligner",
        hdl_toplevel_module="instruction_aligner",
        description="IF-stage instruction aligner tests",
    ),
    "rvc_decompressor": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.test_rvc_decompressor",
        hdl_toplevel_module="rvc_decompressor",
        description="IF-stage RVC decompressor tests",
    ),
    "c_ext_state": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.test_c_ext_state",
        hdl_toplevel_module="c_ext_state",
        description="IF-stage C-extension state controller tests",
    ),
    "if_stage": CocotbRunConfig(
        python_test_module="cocotb_tests.if_stage.test_if_stage",
        hdl_toplevel_module="if_stage",
        description="IF-stage top-level integration tests",
    ),
    "pd_stage": CocotbRunConfig(
        python_test_module="cocotb_tests.pd_stage.test_pd_stage",
        hdl_toplevel_module="pd_stage",
        description="PD-stage unit tests including exact native/RVC redirect targets",
    ),
    "id_stage": CocotbRunConfig(
        python_test_module="cocotb_tests.id_stage.test_id_stage",
        hdl_toplevel_module="id_stage",
        description="ID-stage top-level unit tests",
    ),
    "tomasulo_wrapper": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.tomasulo_wrapper.test_tomasulo_wrapper",
        hdl_toplevel_module="tomasulo_wrapper",
        description="Tomasulo integration tests with production dispatch done repair",
        verilator_extra_args=("-GENABLE_DISPATCH_DONE_REPAIR=1",),
    ),
    "tomasulo_wrapper_split_rs": CocotbRunConfig(
        python_test_module="cocotb_tests.tomasulo.tomasulo_wrapper.test_tomasulo_wrapper_split_rs",
        hdl_toplevel_module="tomasulo_wrapper",
        description=(
            "Tomasulo wrapper tests with production split-RS dispatch and done repair"
        ),
        verilator_extra_args=(
            "-GSPLIT_RS_DISPATCH=1",
            "-GENABLE_DISPATCH_DONE_REPAIR=1",
        ),
    ),
    # Directed machine-mode trap/interrupt tests run on the cpu_tb harness
    # (one instruction fed per ready cycle into the cpu_ooo core). Collected by
    # pytest so the cpu_tb suites cannot rot invisibly again (the harness once
    # sat broken -- missing the served-window tags -- with nothing in CI noticing);
    # filter to a single function with --testcase when running by hand.
    "directed_traps": CocotbRunConfig(
        python_test_module="cocotb_tests.test_directed_traps",
        hdl_toplevel_module="cpu_tb",
        description="Directed M-mode trap/interrupt tests (cpu_tb directed suite)",
    ),
    # The cpu_tb suites below predate the OOO integration. directed_atomics
    # and compressed have been ported (commit-event / settle waits on the
    # maintained DUTInterface helpers, as test_directed_traps was) and pass;
    # they stay CLI-only pending a decision to add them to CI.
    # directed_multicycle and cpu_random still assume in-order fixed
    # latencies: cpu_random's monitors align full-regfile/PC snapshots to
    # o_vld by fetch ordinal with fixed IF->WB offsets, which the OOO core's
    # variable commit latency, 2-wide retire, and wrong-path squashes break --
    # porting it means a commit-indexed scoreboard. Their ISA coverage is
    # meanwhile gated in CI by the rv64ua/rv64uc/rv64um riscv-tests, the
    # arch-compliance matrix, and the ddr_atomic_test/c_ext_test real
    # programs. Flip include_in_pytest after porting.
    "directed_atomics": CocotbRunConfig(
        python_test_module="cocotb_tests.test_directed_atomics",
        hdl_toplevel_module="cpu_tb",
        description="Directed LR.W/SC.W atomic tests (cpu_tb directed suite)",
        include_in_pytest=False,
    ),
    "directed_multicycle": CocotbRunConfig(
        python_test_module="cocotb_tests.test_directed_multicycle",
        hdl_toplevel_module="cpu_tb",
        description="Directed back-to-back multi-cycle op tests (cpu_tb; NEEDS PORTING to OOO)",
        include_in_pytest=False,
    ),
    "compressed": CocotbRunConfig(
        python_test_module="cocotb_tests.test_compressed",
        hdl_toplevel_module="cpu_tb",
        description="RISC-V C-extension directed tests (cpu_tb directed suite)",
        include_in_pytest=False,
    ),
    "cpu_random": CocotbRunConfig(
        python_test_module="cocotb_tests.test_cpu",
        hdl_toplevel_module="cpu_tb",
        description="Constrained-random instruction regression (cpu_tb; NEEDS PORTING to OOO: commit-indexed scoreboard)",
        include_in_pytest=False,
    ),
}

# Real-program test names: registry entries that build an app and are collected
# by pytest (excludes the unit benches, which have no app_name)
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

# Real-program tests that do NOT run in the ddr memory tier
# (FROST_COCOTB_MEM_CONFIG=ddr):
#   - *_fetch_fuzz: a different -G build (FETCH_VALID_FUZZ=1), orthogonal to tier.
#   - ddr_*: already DDR-focused (execute-from-DDR, SMC, cached-region writes at
#     CACHED_BASE) -- a whole-program DDR relocation would be redundant or clobber
#     their fixed-address writes; they run in the bram-tier job as today.
DDR_TIER_EXCLUDE = {
    name
    for name in REAL_PROGRAM_TESTS
    if name.endswith("_fetch_fuzz") or name.startswith("ddr_")
}


# =============================================================================
# CocotbRunner Class
# =============================================================================


class CocotbRunner:
    """Run Cocotb (Coroutine-based Cosimulation TestBench) simulations.

    Manages simulator setup, environment configuration, and test execution
    for FROST CPU verification using Cocotb Python testbench.
    """

    def __init__(
        self,
        python_test_module: str,
        hdl_toplevel_module: str,
        app_name: str | None = None,
        verilator_extra_args: tuple[str, ...] = (),
        extra_env: tuple[tuple[str, str], ...] = (),
    ) -> None:
        """Initialize Cocotb test runner.

        Args:
            python_test_module: Python module containing Cocotb tests (e.g., "cocotb_tests.test_cpu")
            hdl_toplevel_module: Top-level HDL module name (e.g., "cpu_tb")
            app_name: Optional application name to compile and load (e.g., "hello_world")
            verilator_extra_args: Extra Verilator args for this build.
        """
        self.python_test_module = python_test_module
        self.hdl_toplevel_module = hdl_toplevel_module
        self.app_name = app_name
        self.verilator_extra_args = verilator_extra_args
        # Registry-driven environment overrides. Applied to the process
        # environment so the app build (compile_app's make) and the
        # simulation build (setup_environment's os.environ copy) both see
        # them.
        self.extra_env = extra_env
        for key, value in extra_env:
            os.environ[key] = value
        # Seed-sweep workers share sw/apps/<app> and the tests/sw*.mem
        # symlinks; the sweep parent compiles once and sets this so workers
        # skip the (racy) per-run clean+recompile and leave symlink cleanup
        # to the parent.
        self.skip_app_compile = False
        self.test_directory = Path(__file__).parent.resolve()
        self.repository_root_directory = self.test_directory.parent
        # Memory tier for the compiled app (real-program tests). The ddr CI job
        # sets FROST_COCOTB_MEM_CONFIG=ddr to run every program from cached DDR.
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
        # External FROST_VERILATOR_EXTRA_ARGS reaches the build (composed in
        # _get_environment_variables), so it must reach the signature too, or
        # changing it between runs would silently reuse a stale Vtop.
        external_verilator_args = os.environ.get("FROST_VERILATOR_EXTRA_ARGS", "")
        if external_verilator_args:
            signature = f"{signature} {external_verilator_args}".strip()
        return signature

    def _compile_app(self) -> bool:
        """Compile the application if app_name is set.

        Returns:
            True if compilation succeeded or no app to compile, False on failure.
        """
        if not self.app_name:
            return True

        # Import compile_app from sw/apps directory
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
        """Get the path to the program memory file for the current app."""
        if not self.app_name:
            return None
        app_dir_name = app_build_directory_name(self.app_name)
        return f"../sw/apps/{app_dir_name}/sw.mem"

    @staticmethod
    def _ensure_symlink(link: Path, target: str) -> None:
        """Point link at target, leaving an already-correct symlink untouched.

        Idempotence matters for seed sweeps: parallel workers share the same
        link, and an unconditional unlink+recreate opens a window where a
        sibling's $readmemh sees no file. A lost creation race against a
        sibling pointing at the same target is accepted as success.

        The target must exist: a dangling link makes the RTL's $readmemh
        fail quietly and the affected memory reads as zeros (a missing
        sw64.mem left the fpu_assembly_test data BRAM empty — every load
        returned 0 and the program silently fell through to its done spin).
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
        """Set up environment variables for HDL simulation.

        Returns:
            Dictionary of environment variables for subprocess
        """
        environment_variables = os.environ.copy()

        environment_variables["SIM"] = "verilator"
        environment_variables["ROOT"] = str(self.repository_root_directory)
        # Compose with (never stomp) a caller-provided value: an external
        # FROST_VERILATOR_EXTRA_ARGS appends after the registry args so ad-hoc
        # sweeps (e.g. -GFETCH_VALID_FUZZ_SEED=...) can extend any entry.
        external_verilator_args = os.environ.get("FROST_VERILATOR_EXTRA_ARGS", "")
        environment_variables["FROST_VERILATOR_EXTRA_ARGS"] = " ".join(
            part
            for part in (self._verilator_extra_args_string(), external_verilator_args)
            if part
        )

        # Add verification infrastructure to Python path so cocotb_tests modules are importable
        verif_path = str(self.repository_root_directory / "verif")
        current_pythonpath = environment_variables.get("PYTHONPATH", "")
        if verif_path not in current_pythonpath:
            current_pythonpath = verif_path + ":" + current_pythonpath
        environment_variables["PYTHONPATH"] = current_pythonpath

        # In the ddr tier the behavioral DDR persists across reset and .data is
        # loaded in place (LMA == VMA), so a second run would see the program's
        # mutated memory. Force a single run (the bram tier keeps its default).
        if self.mem_config == "ddr":
            environment_variables["COCOTB_NUM_RUNS"] = "1"

        return environment_variables

    def check_for_failures(
        self, simulation_result: subprocess.CompletedProcess[str]
    ) -> bool:
        """Check if Cocotb reported any test failures.

        Args:
            simulation_result: Completed subprocess from simulation run

        Returns:
            True if test failures detected, False otherwise
        """
        # First check return code - non-zero indicates failure
        if simulation_result.returncode != 0:
            return True

        # If output wasn't captured (standalone mode), trust the return code
        has_captured_output = (
            simulation_result.stdout is not None
            and simulation_result.stderr is not None
        )
        if not has_captured_output:
            return False

        # Check for Cocotb failure indicators in output
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
                # Verify it's an actual test failure, not just in a file path
                output_lines = combined_output.splitlines()
                for line in output_lines:
                    if failure_indicator in line and (
                        "test" in line.lower()
                        or "fail" in line.lower()
                        or "error" in line.lower()
                    ):
                        return True

        # Check for cocotb summary line showing failures
        if "passed=0" in combined_output or "failed=" in combined_output:
            # Look for failed=N where N > 0
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
        """Check if Verilator needs a full rebuild due to toplevel change.

        Returns:
            True if rebuild needed (toplevel changed), False for incremental build.
        """
        toplevel_marker = sim_build_dir / ".last_toplevel"
        cocotb_libs_marker = sim_build_dir / ".last_cocotb_libs"
        verilator_extra_args_marker = sim_build_dir / ".last_verilator_extra_args"
        verilator_binary = sim_build_dir / "Vtop"
        cocotb_libs_dir = str(
            (Path(cocotb.__file__).resolve().parent / "libs").resolve()
        )

        # If sim_build exists with a binary but no marker, force rebuild.
        # This handles stale state from before marker tracking was added or
        # before cocotb/Python environment changes were tracked.
        if verilator_binary.exists() and (
            not toplevel_marker.exists()
            or not cocotb_libs_marker.exists()
            or not verilator_extra_args_marker.exists()
        ):
            return True

        if not toplevel_marker.exists():
            return False  # No previous build, let make handle it

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
            return False

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

    def run_simulation(
        self, check: bool = True, capture_output: bool = True
    ) -> subprocess.CompletedProcess[str]:
        """Run the cocotb simulation."""
        # Compile the application first if needed (sweep workers skip this;
        # the sweep parent compiled once before spawning them)
        if self.app_name and not self.skip_app_compile and not self._compile_app():
            raise RuntimeError(f"Failed to compile application: {self.app_name}")

        original_dir = os.getcwd()
        os.chdir(self.test_directory)
        env = self.setup_environment()
        sim_build_dir = self._get_sim_build_dir(env)
        env["SIM_BUILD"] = str(sim_build_dir)

        try:
            # Skip clean to enable incremental builds when RTL unchanged.
            # However, if the toplevel module changed, we must rebuild.
            needs_clean = self._verilator_needs_rebuild(sim_build_dir)

            if needs_clean and not self._verilator_build_dir_writable(sim_build_dir):
                sim_build_dir = self._fallback_verilator_build_dir()
                env["SIM_BUILD"] = str(sim_build_dir)
                needs_clean = False

            if needs_clean:
                # Don't fail on clean errors (e.g., permission denied on root-owned files)
                subprocess.run(["make", "clean"], check=False)

            # Set up program memory symlinks if needed (low BRAM image + the
            # cached-region DDR image consumed by the behavioral DDR model)
            program_memory_file = self._get_program_memory_file()
            if program_memory_file:
                self._ensure_symlink(Path("sw.mem"), program_memory_file)
                self._ensure_symlink(
                    Path("sw64.mem"),
                    program_memory_file.replace("sw.mem", "sw64.mem"),
                )
                self._ensure_symlink(
                    Path("sw_ddr.mem"),
                    program_memory_file.replace("sw.mem", "sw_ddr.mem"),
                )

            # Run the simulation
            # Explicitly export PYTHONPATH so it's available to child processes (simulator)
            pythonpath = env.get("PYTHONPATH", "")
            cmd = f"export PYTHONPATH='{pythonpath}' && make COCOTB_TEST_MODULES='{self.python_test_module}' TOPLEVEL={self.hdl_toplevel_module}"

            if capture_output:
                result = subprocess.run(
                    ["bash", "-c", cmd],
                    capture_output=True,
                    text=True,
                    env=env,
                    check=check,
                )
            else:
                # Let output stream directly to console
                result = subprocess.run(
                    ["bash", "-c", cmd],
                    env=env,
                    check=check,
                    text=True,
                    stdout=None,  # Don't capture, let it stream to terminal
                    stderr=None,  # Don't capture, let it stream to terminal
                )

            # Update the toplevel marker only after successful build.
            # This ensures we don't mark a toplevel as built if compilation failed.
            if result.returncode == 0:
                self._update_verilator_toplevel_marker(sim_build_dir)

            return result

        finally:
            # Clean up (sweep workers share the symlinks with their siblings;
            # the sweep parent removes them after the whole pool drains)
            if self.app_name and not self.skip_app_compile:
                for mem_name in ("sw.mem", "sw_ddr.mem"):
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
    """Test cases for running real programs on the CPU.

    All real program tests use the same test module and toplevel,
    differing only in which program memory file is loaded.
    """

    @pytest.mark.slow
    @pytest.mark.parametrize("test_name", REAL_PROGRAM_TEST_PARAMS)
    def test_real_program(self, test_name: str, capsys: Any) -> None:
        """Run a real program test through cocotb.

        This parametrized test replaces 14 nearly-identical test methods.
        Pytest will generate test IDs like:
            test_real_program[hello_world]
            test_real_program[coremark]
        """
        mem_config = os.environ.get("FROST_COCOTB_MEM_CONFIG", "bram")
        if mem_config == "ddr" and test_name in DDR_TIER_EXCLUDE:
            pytest.skip(f"{test_name} does not run in the ddr tier (fuzz/ddr-only)")
        run_test(test_name, capsys)


@pytest.mark.cocotb
class TestUnitTests:
    """Tomasulo unit tests (individual OOO components)."""

    @pytest.mark.slow
    @pytest.mark.parametrize("test_name", UNIT_TEST_PARAMS)
    def test_unit(self, test_name: str, capsys: Any) -> None:
        """Run a Tomasulo unit test through cocotb."""
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
    # Set up environment for this specific run
    os.environ["SIM"] = "verilator"
    os.environ["COCOTB_RANDOM_SEED"] = str(seed)
    os.environ["SIM_BUILD"] = os.path.join(temp_dir, f"sim_build_{seed}")
    # Per-worker results file. cocotb's default is results.xml in the shared
    # tests/ CWD, which concurrent workers rm/write/check over each other —
    # the clobbering shows up as phantom FAILs (44/100 in the 2026-07-11
    # tomasulo_wrapper sweep; every "failing" seed passed in isolation).
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
            # Extract relevant error info from output
            combined = (result.stdout or "") + (result.stderr or "")
            # Get last 20 lines for context
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
    """Run multiple simulations with different random seeds in parallel.

    Workers are isolated from each other: each gets its own SIM_BUILD and
    COCOTB_RESULTS_FILE, and for app-based tests the app is compiled once
    here (workers run with skip_app_compile and share the sw*.mem symlinks
    read-only). Without that isolation, concurrent workers clobber the shared
    tests/results.xml and race the app build, reporting phantom failures.

    Args:
        test_name: Name of the test from TEST_REGISTRY
        num_seeds: Number of different seeds to test
        testcase: Optional specific test case to run
        max_workers: Maximum number of parallel workers (default: num_seeds)

    Returns:
        Dictionary with results summary
    """
    # Generate random seeds
    seeds = [random.randint(0, 2**31 - 1) for _ in range(num_seeds)]

    print(f"\n{'='*60}")
    print(f"Seed Sweep: Running {num_seeds} simulations in parallel")
    print(f"Test: {test_name}")
    print(f"Seeds: {seeds}")
    print(f"{'='*60}\n")

    # Compile the app once up front and create the shared sw*.mem symlinks.
    # Workers run with skip_app_compile: per-worker clean_first compiles race
    # each other in sw/apps/<app>, and unlink+recreate of tests/sw.mem opens
    # windows where a sibling's $readmemh sees a missing or half-written image.
    parent_runner = CocotbRunner.from_config(TEST_REGISTRY[test_name])
    if parent_runner.app_name:
        if not parent_runner._compile_app():
            raise RuntimeError(
                f"Failed to compile application: {parent_runner.app_name}"
            )
        program_memory_file = parent_runner._get_program_memory_file()
        if program_memory_file:
            CocotbRunner._ensure_symlink(
                parent_runner.test_directory / "sw.mem", program_memory_file
            )
            CocotbRunner._ensure_symlink(
                parent_runner.test_directory / "sw_ddr.mem",
                program_memory_file.replace("sw.mem", "sw_ddr.mem"),
            )

    results: dict[int, tuple[bool, str]] = {}
    workers = max_workers if max_workers else min(num_seeds, os.cpu_count() or 4)

    with tempfile.TemporaryDirectory(prefix="frost_seed_sweep_") as temp_dir:
        with ProcessPoolExecutor(max_workers=workers) as executor:
            # Submit all jobs
            futures = {
                executor.submit(
                    _run_single_seed, test_name, seed, testcase, temp_dir
                ): seed
                for seed in seeds
            }

            # Collect results as they complete
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
        for mem_name in ("sw.mem", "sw_ddr.mem"):
            mem_path = parent_runner.test_directory / mem_name
            if mem_path.exists() or mem_path.is_symlink():
                mem_path.unlink()

    # Generate report
    passed_seeds = [s for s, (p, _) in results.items() if p]
    failed_seeds = [s for s, (p, _) in results.items() if not p]

    print(f"\n{'='*60}")
    print("SEED SWEEP REPORT")
    print(f"{'='*60}")
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
                f"  ./test_run_cocotb.py {test_name}{testcase_arg} "
                f"--random-seed={seed}"
            )

    print(f"{'='*60}\n")

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

    # Build choices list from registry
    test_choices = sorted(TEST_REGISTRY.keys())

    parser = argparse.ArgumentParser(
        description="Run cocotb simulations for Frost RISC-V CPU",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s hello_world              # Run Hello World
  %(prog)s isa_test                 # Run ISA compliance tests
  %(prog)s --list-tests             # Show available tests from TEST_REGISTRY and exit

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
        help="Which test to run",
    )
    parser.add_argument(
        "--list-tests",
        action="store_true",
        help="List available tests and exit",
    )
    parser.add_argument(
        "--testcase",
        default=None,
        help="Specific cocotb test function to run (sets COCOTB_TEST_FILTER env var)",
    )
    parser.add_argument(
        "--random-seed",
        default=None,
        help="Random seed for reproducibility (sets COCOTB_RANDOM_SEED env var)",
    )
    parser.add_argument(
        "--seed-sweep",
        type=int,
        default=None,
        metavar="N",
        help="Run N simulations with different random seeds in parallel and report results",
    )
    parser.add_argument(
        "--max-workers",
        type=int,
        default=None,
        metavar="W",
        help="Maximum parallel workers for seed sweep (default: min(N, cpu_count))",
    )

    args = parser.parse_args()

    if args.list_tests:
        print("Available cocotb tests (from TEST_REGISTRY):")
        for name, cfg in sorted(TEST_REGISTRY.items()):
            print(f"  {name:20} - {cfg.description}")
        sys.exit(0)

    if args.test is None:
        parser.error("the following arguments are required: test")

    # Handle seed sweep mode
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

    # Set environment based on args
    os.environ["SIM"] = "verilator"
    if args.testcase:
        # Anchor at end for exact match (COCOTB_TEST_FILTER uses regex).
        # We only anchor at end because cocotb may prefix with module path.
        os.environ["COCOTB_TEST_FILTER"] = f"{args.testcase}$"
    if args.random_seed:
        os.environ["COCOTB_RANDOM_SEED"] = args.random_seed

    # Get test configuration from registry
    config = TEST_REGISTRY[args.test]
    runner = CocotbRunner.from_config(config)

    # Run simulation
    result = runner.run_simulation(check=False, capture_output=False)

    if runner.check_for_failures(result):
        print("\nSimulation FAILED! Check output above for details.")
        sys.exit(1)
    else:
        print("\nSimulation completed successfully!")


if __name__ == "__main__":
    main()
