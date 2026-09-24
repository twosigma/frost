# RISC-V debug module: generic JTAG TAP (simulation / portable synthesis),
# debug transport module core, the slice writer that lands the module's
# instruction words in the low BRAM through the programming port, and the
# debug module itself.
$(ROOT)/hw/rtl/cpu_and_mem/debug/jtag_tap.sv
$(ROOT)/hw/rtl/cpu_and_mem/debug/dtm_core.sv
# The slice writer's core->div4 request crossing. Listed here so this file
# list stands alone; frost.f's copy deduplicates when nested.
$(ROOT)/hw/rtl/lib/fifo/dc_fifo.sv
$(ROOT)/hw/rtl/cpu_and_mem/debug/debug_slice_writer.sv
$(ROOT)/hw/rtl/cpu_and_mem/debug/debug_module.sv
