# NIC (Phase 4 slice 2): the net10g MAC/PCS integrated on the coherent DMA
# port. Depends on the library file lists (cdc.f, fifo.f, ram.f) and
# net10g.f; the reset bench harness is listed by tests/Makefile only.

$(ROOT)/hw/rtl/peripherals/nic/nic_pkg.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_irq.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_domain_reset.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_reset_ctrl.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_dma_front.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_byte_pack.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_byte_unpack.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_desc_fetch.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_rx_engine.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_tx_engine.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_csr.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_mac_wrap.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_top.sv
