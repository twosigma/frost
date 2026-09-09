# FIFO primitives library file list
# Generic FIFO implementations for use across the design

# Synchronous distributed RAM FIFO (single clock domain)
$(ROOT)/hw/rtl/lib/fifo/sync_dist_ram_fifo.sv

# Dual-clock FIFO (for synchronous clock domain crossing)
$(ROOT)/hw/rtl/lib/fifo/dc_fifo.sv

# Asynchronous FIFO (Gray pointers, unrelated clocks)
$(ROOT)/hw/rtl/lib/fifo/async_fifo.sv
