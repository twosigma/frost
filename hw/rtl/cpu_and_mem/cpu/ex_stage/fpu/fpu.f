# Floating-point unit (FPU) file list for the F and D extensions.
# One iterative engine runs every F and D compute instruction, one at a time,
# on a single shared adder; loads, stores, and register moves never reach it.
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_engine.sv
