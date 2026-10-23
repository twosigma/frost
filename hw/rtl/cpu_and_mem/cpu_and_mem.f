# CPU and memory subsystem

# Library dependencies (RAM primitives used by regfile, cache, main memory)
-f $(ROOT)/hw/rtl/lib/ram/ram.f

# Cache hierarchy (L1/L2 line caches + AXI bridge + behavioral main memory)
-f $(ROOT)/hw/rtl/lib/cache/cache.f

# Pipeline utilities (stall capture registers)
$(ROOT)/hw/rtl/lib/stall_capture_reg.sv

# RISC-V out-of-order CPU core
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.f

# Word<->line adapter between the request router and the cache hierarchy.
# Listed after the CPU core: its XLEN parameter default references
# riscv_pkg::XLEN (read in via cpu_ooo.f), and Yosys resolves package
# references in parameter defaults only if the package is parsed first.
$(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu_ooo/memory_if/cached_tier_adapter.sv

# Instruction memory with predecode sideband
$(ROOT)/hw/rtl/cpu_and_mem/imem_predecode.sv

# Per-line predecode sideband generation (L1I fill path)
$(ROOT)/hw/rtl/cpu_and_mem/imem_predecode_line.sv

# High-address fetch provider (fetch buffer in front of the L1I)
$(ROOT)/hw/rtl/cpu_and_mem/fetch_provider.sv

# Exact request repeater for low-BRAM metadata fallback misses
$(ROOT)/hw/rtl/cpu_and_mem/low_bram_fetch_presenter.sv

# AIA interrupt controller and the coherent DMA test engine
$(ROOT)/hw/rtl/peripherals/aplic/aplic.sv
$(ROOT)/hw/rtl/peripherals/imsic/imsic_decode.sv
$(ROOT)/hw/rtl/cpu_and_mem/dma_test_engine.sv
$(ROOT)/hw/rtl/cpu_and_mem/memory_error_unit.sv
# RISC-V debug module and JTAG DTM; requires riscv_pkg from the core.
-f $(ROOT)/hw/rtl/cpu_and_mem/debug/debug.f

# On-silicon hang triage (synthesizable boot-hang classifier over UART)
$(ROOT)/hw/rtl/cpu_and_mem/hang_triage.sv

# Data-port read response mux (low BRAM, MMIO, cached tier)
$(ROOT)/hw/rtl/cpu_and_mem/data_mem_response_mux.sv

# Reusable CPU and FROST SoC composition.
$(ROOT)/hw/rtl/cpu_top/cpu_axi_master.sv
$(ROOT)/hw/rtl/cpu_top/cpu_uncached_adapter.sv
$(ROOT)/hw/rtl/cpu_top/cpu_memory_fabric.sv
$(ROOT)/hw/rtl/cpu_top/frost_hart.sv
$(ROOT)/hw/rtl/cpu_top/frost_cluster_memory.sv
$(ROOT)/hw/rtl/cpu_top/cpu_top.sv
$(ROOT)/hw/rtl/soc_top/soc_axi_slave.sv
$(ROOT)/hw/rtl/soc_top/soc_top.sv
$(ROOT)/hw/rtl/platform_top.sv
