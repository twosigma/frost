# ALU (Arithmetic Logic Unit) file list
# Integer ALU with base integer, optional M, B, Zicond, and Zbkb operations
# Note: B = Zba + Zbb + Zbs (full bit manipulation extension)

# 4-cycle pipelined multiplier (DSP48E2-tiled 27x18 partial products)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/alu/multiplier.sv

# 32-stage radix-2 restoring divider (fully pipelined)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/alu/divider.sv

# ALU top-level - integrates all arithmetic and logical operations;
# ENABLE_MULDIV can elaborate out the multiplier/divider for dedicated-M/FU users
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv
