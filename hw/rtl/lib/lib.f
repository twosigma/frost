# FPGA library components file list
# Contains all generic, reusable primitives

# RAM primitives (distributed, block, dual-port, dual-clock)
-f $(ROOT)/hw/rtl/lib/ram/ram.f

# FIFO primitives (sync and async)
-f $(ROOT)/hw/rtl/lib/fifo/fifo.f

# Pipeline utilities
$(ROOT)/hw/rtl/lib/stall_capture_reg.sv
