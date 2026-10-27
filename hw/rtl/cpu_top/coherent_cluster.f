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

# Coherent CPU interfaces and cache controllers.
$(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv
$(ROOT)/hw/rtl/lib/cache/cache_perf_pkg.sv
-f $(ROOT)/hw/rtl/lib/cache/coherence_home.f
$(ROOT)/hw/rtl/lib/cache/coherence_c_payload.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/coherent_rs_capacity.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/coherent_rs_issue2_selector.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/coherent_rs_payload_store.sv
$(ROOT)/hw/rtl/lib/cache/coherent_hart_cache.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/memory_if/coherent_atomic_guard.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/memory_if/coherent_atomic_select.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/coherent_lq_issue_selector.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/coherent_lq_candidate_select.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/coherent_lq_address_store.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/coherent_l0_flags.sv
$(ROOT)/hw/rtl/cpu_and_mem/debug/debug_store_mirror_hold.sv
$(ROOT)/hw/rtl/cpu_and_mem/debug/debug_dirty_next.sv
$(ROOT)/hw/rtl/cpu_and_mem/debug/coherent_debug_request_count.sv
