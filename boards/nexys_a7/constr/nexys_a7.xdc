# Xilinx Design Constraints (XDC) for Nexys A7-100T board
# Pin assignments, I/O standards, and timing constraints for Artix-7 FPGA

# ================================================================
# CLOCK - 100MHz single-ended system clock
# ================================================================
# System clock input
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports i_sysclk]
# 100MHz = 10ns period
create_clock -period 10 -name sysclk [get_ports i_sysclk]

# ================================================================
# UART - Serial communication for debug console
# ================================================================
# UART transmit (directly to FTDI chip - directly to UART_RXD_OUT pin)
set_property -dict {PACKAGE_PIN D4 IOSTANDARD LVCMOS33} [get_ports o_uart_tx]
# UART receive (directly from FTDI chip - directly from UART_TXD_IN pin)
set_property -dict {PACKAGE_PIN C4 IOSTANDARD LVCMOS33} [get_ports i_uart_rx]

# ================================================================
# RESET - CPU reset push-button (active-low)
# ================================================================
# Reset button
set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVCMOS33} [get_ports i_pb_resetn]
