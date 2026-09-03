# FROST RISC-V processor top-level file list: every RTL source used for
# synthesis and simulation. Build scripts expand $(ROOT) to the repository root.

# FIFO library (used for clock domain crossing).
# The RAM library arrives through cpu_and_mem.f.
-f $(ROOT)/hw/rtl/lib/fifo/fifo.f

# CPU and memory subsystem (includes all pipeline stages and RAM library)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu_and_mem.f

# Peripheral modules (UART)
-f $(ROOT)/hw/rtl/peripherals/peripherals.f

# Top-level FROST integration module
$(ROOT)/hw/rtl/frost.sv
