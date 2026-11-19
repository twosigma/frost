# NIC: core-domain engine and pluggable 10G/1G MAC blocks over AXI4-Stream.
# Depends on the library file lists (cdc.f, fifo.f, ram.f), net10g.f, and
# line_port_axi_bridge from cache.f; the reset bench harness is listed by
# tests/Makefile only.

$(ROOT)/hw/rtl/peripherals/nic/nic_pkg.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_irq.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_domain_reset.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_core_reset_ctrl.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_mac_reset_ctrl.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_reset_ctrl.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_dma_front.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_byte_pack.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_byte_unpack.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_desc_fetch.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_rx_engine.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_tx_beat_merge.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_tx_segment.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_tx_engine.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_csr.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_pause_rx.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_pause_rx_wire.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_pause_tx.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_mac_cdc.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_mac_10g.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_mac_1g.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_engine.sv
$(ROOT)/hw/rtl/peripherals/nic/nic_top.sv
