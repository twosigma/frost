# RISC-V CPU core file list (6-stage pipeline)
# RV32IMAFB + Zicsr, with full forwarding and L0 cache
# Note: F = single-precision floating-point, B = Zba + Zbb + Zbs

# Package with all type definitions and pipeline interconnect structures
$(ROOT)/hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv

# Pipeline Stage 1: Instruction Fetch (IF)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/if_stage/if_stage.f

# Pipeline Stage 2: Pre-Decode (PD)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/pd_stage/pd_stage.f

# Pipeline Stage 3: Instruction Decode (ID)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/id_stage/id_stage.f

# Pipeline Stage 4: Execute (EX) - ALU, branches, memory address generation
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/ex_stage.f

# Pipeline Stage 5: Memory Access (MA) - Load completion
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/ma_stage/ma_stage.f

# Pipeline Stage 6: Writeback (WB) - Register file
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/wb_stage/regfile.f

# Pipeline control - hazard detection, forwarding, stalls/flushes
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/control/control.f

# L0 data cache for fast memory access
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/cache/cache.f

# CSR file (Zicsr + Zicntr extensions)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu/csr/csr.f

# Data memory interface arbiter (EX/AMO/FP64 muxing)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/data_mem_arbiter.sv

# CPU top-level integration
$(ROOT)/hw/rtl/cpu_and_mem/cpu/cpu.sv
