# FPGA library components file list: generic primitives shared across the design

# RAM primitives (distributed, block, UltraRAM, dual-clock)
-f $(ROOT)/hw/rtl/lib/ram/ram.f

# Clock-domain-crossing primitives (synchronizers, reset, Gray counters)
-f $(ROOT)/hw/rtl/lib/cdc/cdc.f

# FIFO primitives (single-clock, dual-clock, asynchronous)
-f $(ROOT)/hw/rtl/lib/fifo/fifo.f

# Pipeline utilities
$(ROOT)/hw/rtl/lib/stall_capture_reg.sv
