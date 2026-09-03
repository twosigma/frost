# Floating-Point Unit (FPU) file list - F and D extension support
# IEEE 754 single- and double-precision operations (FP_WIDTH 32 or 64)

# Shared utilities used by all FP arithmetic operations
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_lzc.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_classify_operand.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_operand_unpacker.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_subnorm_shift.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_result_assembler.sv

# Short fixed-latency operations. Sign-inject and classify take 1 cycle.
# Compare and the two convert units are non-pipelined, 3 and 5 cycles.
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_sign_inject.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_classify.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_compare.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_convert.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_convert_sd.sv

# Add (non-pipelined, 10 cycles) and multiply (fully pipelined)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_adder.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_multiplier.sv

# Divide and square root. Both are fully pipelined, 36 stages at SP and
# 65 at DP, so they accept a new operation every cycle.
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_divider.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_sqrt.sv

# Fused multiply-add (fully pipelined, 16 cycles)
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
