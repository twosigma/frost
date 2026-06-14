# CPU and memory subsystem file list
# Includes RISC-V CPU core and main memory

# Library dependencies (RAM primitives used by regfile, cache, main memory)
-f $(ROOT)/hw/rtl/lib/ram/ram.f

# Cache hierarchy (L1/L2 line caches + AXI bridge + behavioral main memory)
-f $(ROOT)/hw/rtl/lib/cache/cache.f

# Word<->line adapter between the request router and the cache hierarchy
$(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/memory_if/cached_tier_adapter.sv

# Pipeline utilities (stall capture registers)
$(ROOT)/hw/rtl/lib/stall_capture_reg.sv

# RISC-V OOO CPU core (Tomasulo out-of-order with all submodules)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.f

# Instruction memory with predecode sideband
$(ROOT)/hw/rtl/cpu_and_mem/imem_predecode.sv

# Per-line predecode sideband generation (L1I fill path)
$(ROOT)/hw/rtl/cpu_and_mem/imem_predecode_line.sv

# Quadrant-steered fetch window provider (BRAM + two-line L1I buffer)
$(ROOT)/hw/rtl/cpu_and_mem/fetch_provider.sv

# CPU and memory integration module
$(ROOT)/hw/rtl/cpu_and_mem/cpu_and_mem.sv
