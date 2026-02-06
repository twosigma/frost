# Pipeline control unit file list
# Hazard detection, forwarding, stall/flush control, trap handling, and atomics

# Forwarding unit - resolves integer RAW data hazards by forwarding from MA/WB to EX
$(ROOT)/hw/rtl/cpu_and_mem/cpu/control/forwarding_unit.sv

# F extension: FP forwarding unit - resolves FP RAW hazards (3 source operands for FMA)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/control/fp_forwarding_unit.sv

# Hazard resolution unit - manages pipeline stalls and flushes
$(ROOT)/hw/rtl/cpu_and_mem/cpu/control/hru_fp_hazards.sv
$(ROOT)/hw/rtl/cpu_and_mem/cpu/control/hazard_resolution_unit.sv

# Trap unit - handles exceptions and interrupts for RTOS support
$(ROOT)/hw/rtl/cpu_and_mem/cpu/control/trap_unit.sv

# A extension: LR/SC reservation register for atomics
$(ROOT)/hw/rtl/cpu_and_mem/cpu/control/lr_sc_reservation.sv
