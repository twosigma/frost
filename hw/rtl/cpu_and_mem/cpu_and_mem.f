# CPU and memory subsystem file list
# Includes RISC-V CPU core and main memory

# Library dependencies (RAM primitives used by regfile, cache, main memory)
-f $(ROOT)/hw/rtl/lib/ram/ram.f

# Pipeline utilities (stall capture registers)
$(ROOT)/hw/rtl/lib/stall_capture_reg.sv

# RISC-V CPU core (6-stage pipeline with all submodules)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu.f

# CPU and memory integration module
$(ROOT)/hw/rtl/cpu_and_mem/cpu_and_mem.sv
