# AXI4 library: the SoC's DMA interconnect and its bridge into cpu_top's
# coherent ingress, and simulation-only protocol checks. axi_coherent_bridge
# uses sdp_dist_ram from ram.f, which an including list supplies; the mux's
# bench harness is listed by tests/Makefile only.
$(ROOT)/hw/rtl/lib/axi/axi_checker.sv
$(ROOT)/hw/rtl/lib/axi/axi_mux.sv
$(ROOT)/hw/rtl/lib/axi/axi_coherent_bridge.sv
