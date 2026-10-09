# ALU (Arithmetic Logic Unit) file list
# Integer ALU with base integer, B, Zicond, and Zbkb operations, where
# B = Zba + Zbb + Zbs (the full bit manipulation extension).
# int_muldiv_shim includes the multiplier and divider through fu_shims.f.
# M-extension operations do not execute in alu.sv.

# Fully pipelined multiplier (sign correction around the shared DSP-tiled
# unsigned core, latency riscv_pkg::MulPipeDepth)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/alu/multiplier.sv

# Iterative radix-2 restoring divider (one quotient bit per cycle, one
# operation at a time)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/alu/divider.sv

# ALU: single-cycle combinational integer, logic, and bit-manipulation
# datapath
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv
