# Floating-point unit (FPU) file list for the F and D extensions.
# The iterative engine handles FP computation and register moves.
# Loads and stores use the memory path.
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_engine.sv
# Pipelined multiply-add (FADD/FSUB/FMUL/FMA, single and double) and its
# leading-zero counter
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_pipe_lzc.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_fma_pipe.sv
# Radix-16 divider (FDIV.S, FDIV.D)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_div_unit.sv
