# Execute (EX) stage file list
# ALU, branches, memory address generation

# Arithmetic Logic Unit with multiply/divide support
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.f

# Branch and jump resolution unit
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/branch_jump_unit.sv

# Branch redirect unit - misprediction detection and BTB/RAS recovery
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/branch_redirect_unit.sv

# Store unit - memory address calculation and byte alignment
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/store_unit.sv

# Exception detector - ECALL, EBREAK, misaligned access detection
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/exception_detector.sv

# EX stage integration module
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/ex_stage.sv
