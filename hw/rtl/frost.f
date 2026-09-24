# FROST top-level file list: every RTL source of the frost top, for simulation
# and synthesis. Build scripts expand $(ROOT) to the repository root.

# FIFO and clock-crossing libraries.
# The RAM library arrives through cpu_and_mem.f.
-f $(ROOT)/hw/rtl/lib/fifo/fifo.f
-f $(ROOT)/hw/rtl/lib/cdc/cdc.f

# The NIC: the net10g MAC/PCS and the blocks that put it on the coherent DMA
# port. Listed before cpu_and_mem.f, which instantiates nic_top.
-f $(ROOT)/hw/rtl/net10g/net10g.f
-f $(ROOT)/hw/rtl/peripherals/nic/nic.f

# CPU and memory subsystem (includes all pipeline stages and RAM library)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu_and_mem.f

# Peripheral modules (UART)
-f $(ROOT)/hw/rtl/peripherals/peripherals.f

# Top-level FROST integration module
$(ROOT)/hw/rtl/frost.sv
