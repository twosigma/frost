# ALU (Arithmetic Logic Unit) file list
# RV32IMAB ALU with base integer, M, A, and B extensions
# Note: B = Zba + Zbb + Zbs (full bit manipulation extension)

# 4-cycle pipelined multiplier (DSP48E2-tiled 27x18 partial products)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/alu/multiplier.sv

# 32-stage radix-2 restoring divider (fully pipelined)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/alu/divider.sv

# ALU top-level - integrates all arithmetic and logical operations
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv
