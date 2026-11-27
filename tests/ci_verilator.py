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

"""Select Cocotb jobs for the CI workflow."""

import json
import os
from pathlib import Path
from typing import Any


TOGGLE_BUDGET_FILE = Path(__file__).with_name("fixtures") / "ci_toggle_budgets.json"
TOGGLE_JOB_CEILING_MINUTES = 360


# Shards on the two memory axes use the shared RTL defaults. The include
# entries select a single axis for fixed-layout programs and unit benches.
VERILATOR_MATRIX: dict[str, Any] = {
    "mem_config": ["bram", "ddr"],
    "shard": [
        {
            "name": "Real Programs (CoreMark)",
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": "[coremark] or [coremark_profile]",
            # The BRAM run records a performance model calibration trace.
            "calibration_test": "coremark",
        },
        {
            "name": "Real Programs (AMO and timer torture)",
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": "[amo_irq_torture_sim] or [tick_torture_sim]",
        },
        {
            "name": "Real Programs (Cache stress)",
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "[drain_trapframe_test] or [restore_window_stress] or "
                "[mret_drain_deadlock] or [linux_clksrc_faithful] or [trap_s2l_fwd] or "
                "[pde_return_hazard] or [nic_dma_stress]"
            ),
        },
        {
            "name": "Real Programs (Privilege and MMU)",
            "timeout_minutes": 280,
            "coverage": ["ddr"],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "[csr_test] or [umode_test] or [pma_fault_test] or [vm_test] or "
                "[itlb_test] or [satp_drain_test] or [ad_fault_test] or [smode_test] "
                "or [csr_rmw_test] or [ptw_bus_fault_test] or [ptw_recovery_test] or "
                "[sum_toggle_test] or [asid_test] or [svinval_test] or [svpbmt_test] "
                "or [svpbmt_test_assert] or [svpbmt_test_2g] or [svpbmt_bus_error]"
            ),
        },
        {
            "name": "Real Programs (Interrupts)",
            "coverage": ["ddr"],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter_extra": {"ddr": "[irq_take_hold_test]"},
            "pytest_filter": (
                "[imsic_csr_test] or [imsic_msi_test] or [imsic_collision_test] or "
                "[timer_replay_test] or [imsic_aplic_coexist_test] or [aplic_test] or "
                "[sstc_test] or [sscofpmf_test] or [ns16550_irq_console_test] or "
                "[wfi_mepc_test] or [wfi_drain_mepc_test] or [mret_timer_resume_test] "
                "or [mtimer_stress] or [wfi_lost_tick] or [irq_mie_window] or "
                "[ns16550_test] or [clint_test] or "
                "[linux_irq_ddr_test] or [linux_irq_active_ddr_test] or "
                "[linux_irq_stack_slot_test] or [linux_irq_find_next_slot_test]"
            ),
        },
        {
            "name": "Real Programs (CPU and fetch)",
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "[branch_pred_test] or [c_ext_test] or [cf_ext_test] or [call_stress] "
                "or [fpu_test] or [fpu_assembly_test] or [isa_test] or [rv64_smoke] or "
                "[rv64_amo_test] or [spanning_test] or [ras_test] or [ras_stress_test] "
                "or [tomasulo_test] or [tomasulo_perf] or [jal_target_seam] or "
                "[fetch_lead_repro] or [fetch_stall_repro] or [window_skip_repro] or "
                "[l1i_set_test]"
            ),
        },
        {
            "name": "Real Programs (32 KiB L1I)",
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "[smc_fencei_test_l1i32] or [ifread_test_l1i32] or "
                "[l1i_set_test_l1i32] or [l1i_set_test_l1i32_hw_sweep]"
            ),
        },
        {
            "name": "Real Programs (Load queue slots)",
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": "[lq_stale_slot_probe]",
        },
        {
            "name": "Real Programs (C library and RTOS)",
            "coverage": ["ddr"],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "[sprintf_test] or [strings_test] or [memory_test] or [freertos_demo] "
                "or [packet_parser]"
            ),
        },
        {
            "name": "Real Programs (DMA, NIC and coherence)",
            "coverage": ["ddr"],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "[nic_loopback] or [nic_echo] or [dma_torture] or "
                "[cached_store_burst_test] or [dma_torture_equal_lines] or "
                "[ptw_coherence_test] or [ptw_coherence_test_equal_lines] or "
                "[ifread_test] or [ifread_test_equal_lines] or [smc_fencei_test] or "
                "[smc_fencei_test_equal_lines] or [ddr_test_equal_lines] or "
                "[ddr_exec_test_equal_lines] or [ddr_atomic_test_equal_lines] or "
                "[async_hello_world] or [async_nic_loopback] or [async_dma_torture]"
            ),
        },
        {
            "name": "Real Programs (Debug and UART)",
            "timeout_minutes": 270,
            "coverage": ["bram"],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter_extra": {"bram": "[irq_take_hold_test]"},
            "pytest_filter": (
                "[debug_test] or [debug_fence_test] or [debug_openocd_test] or "
                "[debug_fatal_stop] or "
                "[debug_fatal_stop_with_engine] or "
                "[bram_reload] or [instret_test] or [hello_world] or [uart_burst] or "
                "[uart_echo] or [print_clock_speed] or [sysreset_test]"
            ),
        },
        {
            "name": "Real Programs (Zicboz)",
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "[cbo_zero_test] or [cbo_zero_test_assert] or "
                "[cbo_zero_test_equal_lines]"
            ),
        },
        {
            "name": "Real Programs (Zicboz pages)",
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": "[cbo_zero_pages]",
        },
        {
            "name": "Real Programs (Zicboz eviction)",
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": "[cbo_zero_pages_thrash] or [cbo_zero_pages_thrash_sync]",
        },
        {
            "name": "Real Programs (Full-line stores)",
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": "[full_line_test]",
        },
        {
            "name": "Real Programs (Store-stream benchmark)",
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": "[store_fill_bench]",
        },
        {
            "name": "Real Programs (Node reuse)",
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": "[node_reuse_test]",
        },
        # One register stage between the hart and the cluster memory
        # (MEMORY_LINK_STAGES=1).
        {
            "name": "Real Programs (Memory link stage, DDR programs)",
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "[ddr_bench_link1] or [ddr_atomic_test_link1] or [ddr_mlp_test_link1]"
            ),
        },
        {
            "name": "Real Programs (Memory link stage, other programs)",
            "coverage": ["ddr"],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "[coremark_link1] or [csr_test_link1] or [dma_torture_link1] or "
                "[ptw_coherence_test_link1] or [cached_store_burst_test_link1] or "
                "[cbo_zero_test_link1] or [cbo_zero_pages_link1]"
            ),
        },
        {
            "name": "Real Programs (Memory link stage, full-line stores)",
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": "[full_line_test_link1]",
        },
        # The PAUSE and RAS benchmarks share profiling builds.
        {
            "name": "Real Programs (Runtime benchmarks)",
            "coverage": ["bram"],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": "[pause_test] or [ras_slot_bench] or [ras_repair_bench]",
        },
        # The VLEN 256 programs share one build, split into two shards to keep
        # regular BRAM runs well inside the four-hour default timeout. Every
        # other registry name starting with vec_ selects the second shard.
        {
            "name": "Real Programs (Vector programs, memory and strides)",
            "coverage": ["bram"],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "[vec_state_test] or [vec_order_test_v256] or [vec_mem_test_v256] or "
                "[vec_index_test_v256] or [vec_ff_test_v256] or "
                "[vec_segment_test_v256] or [vec_stride_test_v256] or "
                "[vec_debug_partial]"
            ),
        },
        {
            "name": "Real Programs (Vector programs)",
            "coverage": ["bram"],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "[vec_ and not ([vec_state_test] or [vec_order_test_v256] or "
                "[vec_mem_test_v256] or [vec_index_test_v256] or [vec_ff_test_v256] "
                "or [vec_segment_test_v256] or [vec_stride_test_v256] or "
                "[vec_debug_partial])"
            ),
        },
        {
            "name": "Real Programs (NIC stress)",
            "coverage": ["bram"],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": "[nic_bench] or [nic_sg_loopback] or [nic_rate]",
        },
        {
            "name": "Real Programs (Memory stress)",
            "coverage": ["bram"],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "[l2_capacity_chase_capacity] or [l2_capacity_chase_smoke] or "
                "[misaligned_test] or [sstvala_fault_test] or [ddr_reset_distribution] "
                "or [ddr_reset_distribution_async] or [ddr_hpm_refill_test]"
            ),
        },
        {
            "name": "Real Programs (Cache management and memory errors)",
            "coverage": ["bram"],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "[probe_zero_twin] or "
                "[cbo_mgmt_test] or [cbo_mgmt_test_assert] or [nic_cmo_loopback] or "
                "[memerr_test] or [memerr_test_seeded] or [memerr_readback] or "
                "[ecc_scrub_test] or [fatal_stop_irq] or [fatal_stop_irq_with_engine]"
            ),
        },
        {
            "name": "Real Programs (Self-modifying code and fence.i)",
            "coverage": ["bram"],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "[smc_stale_test] or [smc_torture] or [smc_predict_test] or "
                "[fencei_bench]"
            ),
        },
        {
            "name": "Real Programs (Fetch and branch prediction)",
            "coverage": ["bram"],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "[fefuzz_1] or [fefuzz_4] or [fefuzz_7] or [fefuzz_11] or "
                "[fefuzz_13] or [fefuzz_19] or [fefuzz_22] or [fefuzz_23] or "
                "[pd_itt_slot2] or [bpred_trap_pair_test] or [bpred_probe] or "
                "[mispen_probe] or [btb_mode_alias_test] or "
                "[fast_btb_contract_test] or [odd_halfword_pred_test]"
            ),
        },
        {
            "name": "Real Programs (ISA, NAPOT and pointer masking)",
            "coverage": ["bram"],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "[fs_off_test] or [zicbop_test] or [zawrs_test] or [zihpm_test] or "
                "[svnapot_test] or [svnapot_test_assert] or [sstvala_test] or "
                "[svpbmt_cmo_test] or [pm_test] or [pm_test_assert]"
            ),
        },
        # The complement runs unlisted non-CoreMark-PRO programs.
        # OpenSBI and registry budgets above 10 million cycles need named
        # shards. Give each OpenSBI boot its own BRAM-only include entry.
        # Keep the exclusions in sync with every named shard.
        {
            "name": "Real Programs (Runtime and other)",
            "coverage": ["bram"],
            "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
            "pytest_filter": (
                "not ([coremark] or [coremark_profile] or [amo_irq_torture_sim] or "
                "[tick_torture_sim] or [drain_trapframe_test] or "
                "[restore_window_stress] or [mret_drain_deadlock] or "
                "[linux_clksrc_faithful] or [trap_s2l_fwd] or [pde_return_hazard] or "
                "[nic_dma_stress] or [csr_test] or [umode_test] or [pma_fault_test] or "
                "[vm_test] or [itlb_test] or [satp_drain_test] or [ad_fault_test] or "
                "[smode_test] or [csr_rmw_test] or [ptw_bus_fault_test] or "
                "[ptw_recovery_test] or [sum_toggle_test] or [asid_test] or "
                "[svinval_test] or [svpbmt_test] or [svpbmt_test_assert] or "
                "[svpbmt_test_2g] or [svpbmt_bus_error] or [imsic_csr_test] or "
                "[imsic_msi_test] or [imsic_collision_test] or [timer_replay_test] or "
                "[imsic_aplic_coexist_test] or [aplic_test] or [sstc_test] or "
                "[sscofpmf_test] or [ns16550_irq_console_test] or [wfi_mepc_test] or "
                "[wfi_drain_mepc_test] or [mret_timer_resume_test] or [mtimer_stress] "
                "or [wfi_lost_tick] or [irq_mie_window] or [irq_take_hold_test] or "
                "[ns16550_test] or [clint_test] or [linux_irq_ddr_test] or "
                "[linux_irq_active_ddr_test] or [linux_irq_stack_slot_test] or "
                "[linux_irq_find_next_slot_test] or [branch_pred_test] or [c_ext_test] "
                "or [cf_ext_test] or [call_stress] or [fpu_test] or "
                "[fpu_assembly_test] or [isa_test] or [rv64_smoke] or [rv64_amo_test] "
                "or [spanning_test] or [ras_test] or [ras_stress_test] or "
                "[tomasulo_test] or [tomasulo_perf] or [jal_target_seam] or "
                "[fetch_lead_repro] or [fetch_stall_repro] or [window_skip_repro] or "
                "[lq_stale_slot_probe] or [sprintf_test] or [strings_test] or "
                "[memory_test] or [freertos_demo] or [packet_parser] or [nic_loopback] "
                "or [nic_echo] or [dma_torture] or [cached_store_burst_test] or "
                "[dma_torture_equal_lines] or [ptw_coherence_test] or "
                "[ptw_coherence_test_equal_lines] or [ifread_test] or "
                "[ifread_test_equal_lines] or [smc_fencei_test] or "
                "[smc_fencei_test_equal_lines] or [ddr_test_equal_lines] or "
                "[ddr_exec_test_equal_lines] or [ddr_atomic_test_equal_lines] or "
                "[debug_test] or [debug_fence_test] or [debug_openocd_test] or "
                "[debug_fatal_stop] or "
                "[debug_fatal_stop_with_engine] or "
                "[bram_reload] or [instret_test] or [hello_world] or [uart_burst] or "
                "[uart_echo] or [print_clock_speed] or [sysreset_test] or [ddr_test] "
                "or [ddr_exec_test] or [ddr_smc_test] or [ddr_heap_test] or "
                "[ddr_mlp_test] or [ddr_atomic_test] or [ddr_bench] or "
                "[hello_world_fetch_fuzz] or [branch_pred_test_fetch_fuzz] or "
                "[c_ext_test_fetch_fuzz] or [call_stress_fetch_fuzz] or "
                "[itlb_test_fetch_fuzz] or [opensbi_smoke] or "
                "[opensbi_smoke_no_misaligned_hw] or [opensbi_reset_cold] or "
                "[opensbi_reset_warm] or [isa_test_sram_macros] or "
                "[ddr_test_sram_macros] or [ddr_exec_test_sram_macros] or "
                "[nic_loopback_sram_macros] or [cache_counters_openocd] or "
                "[hw_debug_check_openocd] or "
                "[async_hello_world] or [async_nic_loopback] or [async_dma_torture] or "
                "[cbo_zero_test] or [cbo_zero_test_assert] or "
                "[cbo_zero_test_equal_lines] or [cbo_zero_pages] or "
                "[cbo_zero_pages_thrash] or [cbo_zero_pages_thrash_sync] or "
                "[cbo_zero_pages_board] or [cbo_zero_pages_board_ddr] or "
                "[cbo_zero_bench] or [full_line_test] or [store_fill_bench] or "
                "[node_reuse_test] or "
                "[fencei_jit_bench] or [ddr_bench_link1] or [ddr_atomic_test_link1] or "
                "[ddr_mlp_test_link1] or [coremark_link1] or [csr_test_link1] or "
                "[dma_torture_link1] or [ptw_coherence_test_link1] or "
                "[cached_store_burst_test_link1] or [cbo_zero_test_link1] or "
                "[cbo_zero_pages_link1] or [full_line_test_link1] or [l1i_set_test] or "
                "[smc_fencei_test_l1i32] or [ifread_test_l1i32] or "
                "[l1i_set_test_l1i32] or [l1i_set_test_l1i32_hw_sweep] or [nic_bench] "
                "or [nic_sg_loopback] or [nic_rate] or [l2_capacity_chase_capacity] or "
                "[l2_capacity_chase_smoke] or [cbo_mgmt_test] or "
                "[probe_zero_twin] or "
                "[cbo_mgmt_test_assert] or [nic_cmo_loopback] or [misaligned_test] or "
                "[memerr_test] or [memerr_test_seeded] or [memerr_readback] or "
                "[ecc_scrub_test] or [fatal_stop_irq] or [fatal_stop_irq_with_engine] "
                "or [sstvala_fault_test] or [ddr_reset_distribution] "
                "or [ddr_reset_distribution_async] or [ddr_hpm_refill_test] or "
                "[pause_test] or [ras_slot_bench] or [ras_repair_bench] or "
                "[smc_stale_test] or [smc_torture] or [smc_predict_test] or "
                "[fencei_bench] or [fefuzz_1] or [fefuzz_4] or [fefuzz_7] or "
                "[fefuzz_11] or [fefuzz_13] or [fefuzz_19] or [fefuzz_22] or "
                "[fefuzz_23] or [pd_itt_slot2] or [bpred_trap_pair_test] or "
                "[bpred_probe] or [mispen_probe] or [btb_mode_alias_test] or "
                "[fast_btb_contract_test] or [odd_halfword_pred_test] or "
                "[fs_off_test] or [zicbop_test] or [zawrs_test] or [zihpm_test] or "
                "[svnapot_test] or [svnapot_test_assert] or [sstvala_test] or "
                "[svpbmt_cmo_test] or [pm_test] or [pm_test_assert] or [vec_)"
            ),
        },
        {
            "name": "Real Programs (CoreMark-PRO / core)",
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and coremark_pro",
            "pytest_filter": "[coremark_pro_core]",
        },
        {
            "name": "Real Programs (CoreMark-PRO / loops)",
            "timeout_minutes": 340,
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and coremark_pro",
            "pytest_filter": "[coremark_pro_loops]",
        },
        {
            "name": "Real Programs (CoreMark-PRO / nnet)",
            "timeout_minutes": 300,
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and coremark_pro",
            "pytest_filter": "[coremark_pro_nnet]",
        },
        {
            "name": "Real Programs (CoreMark-PRO / cjpeg, linear_alg, parser, radix2, sha, zip)",
            "coverage": [],
            "pytest_mark": "cocotb and cocotb_real_program and coremark_pro",
            "pytest_filter": (
                "[coremark_pro_cjpeg] or [coremark_pro_linear_alg] or "
                "[coremark_pro_parser] or [coremark_pro_radix2] or [coremark_pro_sha] "
                "or [coremark_pro_zip]"
            ),
        },
    ],
    "include": [
        # These configurations select their own program layout and DDR
        # geometry. Long runs have their own shards.
        {
            "mem_config": "bram",
            "shard": {
                "name": "Real Programs (Zicboz large cache)",
                "coverage": [],
                "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
                "pytest_filter": "[cbo_zero_pages_board] or [cbo_zero_pages_board_ddr]",
            },
        },
        {
            "mem_config": "bram",
            "shard": {
                "name": "Real Programs (Zicboz clearing benchmark)",
                "coverage": [],
                "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
                "pytest_filter": "[cbo_zero_bench]",
            },
        },
        {
            "mem_config": "bram",
            "shard": {
                "name": "Real Programs (Fence.i JIT benchmark)",
                "coverage": [],
                "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
                "pytest_filter": "[fencei_jit_bench]",
            },
        },
        {
            "mem_config": "bram",
            "shard": {
                "name": "Real Programs (DDR probes and fetch fuzz)",
                "coverage": [],
                "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
                "pytest_filter": (
                    "[ddr_test] or [ddr_exec_test] or [ddr_smc_test] or "
                    "[ddr_heap_test] or [ddr_mlp_test] or [ddr_atomic_test] or "
                    "[ddr_bench] or [hello_world_fetch_fuzz] or "
                    "[branch_pred_test_fetch_fuzz] or [c_ext_test_fetch_fuzz] or "
                    "[call_stress_fetch_fuzz] or [itlb_test_fetch_fuzz]"
                ),
            },
        },
        # The SoC uses the ASIC flow's SRAM macros (asic/README.md).
        {
            "mem_config": "bram",
            "shard": {
                "name": "Real Programs (SRAM macros)",
                "coverage": ["bram"],
                "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
                "pytest_filter": (
                    "[isa_test_sram_macros] or [ddr_test_sram_macros] or "
                    "[ddr_exec_test_sram_macros] or [nic_loopback_sram_macros]"
                ),
            },
        },
        # Each OpenSBI boot has a fixed image layout and its own shard.
        {
            "mem_config": "bram",
            "shard": {
                "name": "Real Programs (OpenSBI smoke)",
                "timeout_minutes": 300,
                "coverage": ["bram"],
                "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
                "pytest_filter": "[opensbi_smoke]",
            },
        },
        {
            "mem_config": "bram",
            "shard": {
                "name": "Real Programs (OpenSBI smoke, no misaligned hardware)",
                "timeout_minutes": 300,
                "coverage": ["bram"],
                "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
                "pytest_filter": "[opensbi_smoke_no_misaligned_hw]",
            },
        },
        {
            "mem_config": "bram",
            "shard": {
                "name": "Real Programs (OpenSBI cold reset)",
                "coverage": ["bram"],
                "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
                "pytest_filter": "[opensbi_reset_cold]",
            },
        },
        {
            "mem_config": "bram",
            "shard": {
                "name": "Real Programs (OpenSBI warm reset)",
                "coverage": ["bram"],
                "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
                "pytest_filter": "[opensbi_reset_warm]",
            },
        },
        # The OpenOCD checks of the cache counters and the debug port run
        # from low BRAM in either tier.
        {
            "mem_config": "bram",
            "shard": {
                "name": "Real Programs (Cache counters over OpenOCD)",
                "coverage": [],
                "pytest_mark": "cocotb and cocotb_real_program and not coremark_pro",
                "pytest_filter": "[cache_counters_openocd] or [hw_debug_check_openocd]",
            },
        },
        # The unit benches run serially in two jobs of about equal duration.
        # tests/test_run_cocotb.py assigns each bench to one of them.
        {
            "mem_config": "bram",
            "shard": {
                "name": "Unit Tests A",
                "coverage": ["bram"],
                "pytest_mark": "cocotb and cocotb_unit and cocotb_unit_a",
                "pytest_filter": "test_unit",
            },
        },
        {
            "mem_config": "bram",
            "shard": {
                "name": "Unit Tests B",
                "coverage": ["bram"],
                "pytest_mark": "cocotb and cocotb_unit and cocotb_unit_b",
                "pytest_filter": "test_unit",
            },
        },
    ],
}


def toggle_job_minutes(wall_seconds: int) -> int:
    """Allow 1.8 times the planned wall time, up to the hosted job limit."""
    return min(TOGGLE_JOB_CEILING_MINUTES, (9 * wall_seconds + 299) // 300)


def _toggle_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    budgets = json.loads(TOGGLE_BUDGET_FILE.read_text())
    selected = []
    for row in rows:
        tier, shard = row["mem_config"], row["shard"]
        if tier not in shard["coverage"]:
            continue
        name = shard["name"]
        budget = budgets[tier][name]
        if "excluded_cases" in budget:
            continue
        if name.startswith("Unit Tests"):
            selected.append(
                {
                    "mem_config": tier,
                    "shard": {
                        **shard,
                        "timeout_minutes": toggle_job_minutes(
                            budget["observed_seconds"]
                        ),
                    },
                }
            )
            continue
        for part in budget["parts"]:
            cases = part["case_seconds"]
            planned = part["overhead_seconds"] + sum(cases.values())
            child = dict(shard)
            child.pop("pytest_filter_extra", None)
            child["pytest_filter"] = " or ".join(f"[{case}]" for case in cases)
            child["timeout_minutes"] = toggle_job_minutes(planned)
            if "name" in part:
                child["name"] = f"{name.removesuffix(')')}, {part['name']})"
            selected.append({"mem_config": tier, "shard": child})
    return selected


def job_matrix(*, coverage_only: bool) -> dict[str, list[dict[str, Any]]]:
    """Expand the memory axes and select the budgeted toggle shards on request."""
    rows = [
        {"mem_config": tier, "shard": shard}
        for tier in VERILATOR_MATRIX["mem_config"]
        for shard in VERILATOR_MATRIX["shard"]
    ] + VERILATOR_MATRIX["include"]
    if coverage_only:
        rows = _toggle_rows(rows)
    return {"include": rows}


if __name__ == "__main__":
    matrix = job_matrix(coverage_only=os.environ.get("TOGGLE_COVERAGE") == "true")
    print(json.dumps(matrix, separators=(",", ":")))
