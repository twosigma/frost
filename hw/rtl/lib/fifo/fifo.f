# FIFO primitives library file list
# Generic FIFO implementations for use across the design

# Synchronous distributed RAM FIFO (single clock domain)
$(ROOT)/hw/rtl/lib/fifo/sync_dist_ram_fifo.sv

# Dual-clock FIFO (related clocks with a fixed phase relationship)
$(ROOT)/hw/rtl/lib/fifo/dc_fifo.sv

# Asynchronous FIFO (Gray pointers, unrelated clocks)
$(ROOT)/hw/rtl/lib/fifo/async_fifo.sv
