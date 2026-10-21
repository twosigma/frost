# Standalone CPU integration boundary (no board or peripheral dependencies).
-f $(ROOT)/hw/rtl/lib/ram/ram.f
-f $(ROOT)/hw/rtl/lib/cache/cache.f
$(ROOT)/hw/rtl/lib/stall_capture_reg.sv
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.f
$(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/memory_if/cached_tier_adapter.sv
$(ROOT)/hw/rtl/cpu_and_mem/imem_predecode_line.sv
$(ROOT)/hw/rtl/cpu_and_mem/fetch_provider.sv
$(ROOT)/hw/rtl/cpu_top/cpu_axi_master.sv
$(ROOT)/hw/rtl/cpu_top/cpu_uncached_adapter.sv
$(ROOT)/hw/rtl/cpu_top/cpu_memory_fabric.sv
$(ROOT)/hw/rtl/cpu_top/cpu_top.sv
