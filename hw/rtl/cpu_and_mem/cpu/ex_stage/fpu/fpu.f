# Floating-Point Unit (FPU) file list - F extension support
# Single-precision IEEE 754 floating-point operations

# Shared utilities used by all FP arithmetic operations
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_lzc.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_classify_operand.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_subnorm_shift.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_round.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_result_assembler.sv

# Simple 1-cycle operations
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_sign_inject.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_classify.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_compare.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_convert.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_convert_sd.sv

# Pipelined arithmetic operations
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_adder.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_multiplier.sv

# Sequential operations (stall pipeline)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_divider.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_sqrt.sv

# Fused multiply-add (4-cycle pipelined)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_fma.sv

# FPU sub-unit wrappers (S+D with tracking FSM, NaN-boxing, dest reg)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_adder_unit.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_mult_unit.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_fma_unit.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_compare_unit.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_sign_inject_unit.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_classify_unit.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_div_sqrt_unit.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu_convert_unit.sv

# FPU top-level integration
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fpu.sv
