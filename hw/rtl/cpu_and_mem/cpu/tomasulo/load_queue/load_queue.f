# Load Queue file list
# Circular buffer tracking in-flight load instructions

# Package dependency
$(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv

# Load unit (byte/halfword extraction and sign extension)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ma_stage/load_unit.sv

# Module
$(ROOT)/hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv
