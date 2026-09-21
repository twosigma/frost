# X3 board top-level file list
# Includes FROST core plus X3-specific clock generation, the NIC transceiver
# and JTAG interface

# FROST RISC-V processor core and all submodules
-f $(ROOT)/hw/rtl/frost.f

# Common Xilinx FROST subsystem (JTAG, BRAM controller, CPU)
$(ROOT)/boards/xilinx_frost_subsystem.sv

# X3 power-up DDR4 region writer (ECC needs the array written before a read)
$(ROOT)/boards/x3/x3_ddr_init.sv

# X3 NIC transceiver (GTY wizard core from fpga/build/x3_gty_ip.tcl)
$(ROOT)/boards/x3/x3_nic_gty.sv

# X3 board wrapper with UltraScale+ FPGA primitives
$(ROOT)/boards/x3/x3_frost.sv
