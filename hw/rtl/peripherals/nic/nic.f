# NIC (Phase 4 slice 2): the net10g MAC/PCS integrated on the coherent DMA
# port. Depends on the library file lists (cdc.f, fifo.f, ram.f).

$(ROOT)/hw/rtl/peripherals/nic/nic_pkg.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_irq.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_domain_reset.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_reset_ctrl.sv

# cocotb bench top (reset handshake + the crossing library under it)
$(ROOT)/hw/rtl/peripherals/nic/nic_reset_test_harness.sv
