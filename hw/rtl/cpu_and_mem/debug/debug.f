# RISC-V debug module and JTAG transport.
# cpu_and_mem.f supplies riscv_pkg.sv and sdp_block_ram_dc.sv first.
$(ROOT)/hw/rtl/cpu_and_mem/debug/jtag_tap.sv
$(ROOT)/hw/rtl/cpu_and_mem/debug/dtm_core.sv
# The slice writer's core->div4 request crossing. frost.f also lists it
# through fifo.f; the duplicate is dropped.
$(ROOT)/hw/rtl/lib/fifo/dc_fifo.sv
$(ROOT)/hw/rtl/cpu_and_mem/debug/debug_slice_writer.sv
$(ROOT)/hw/rtl/cpu_and_mem/debug/debug_module.sv
