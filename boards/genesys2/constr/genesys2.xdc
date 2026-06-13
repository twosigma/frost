# Xilinx Design Constraints (XDC) for Genesys2 board
# Pin assignments, I/O standards, and timing constraints for Kintex-7 FPGA

# ================================================================
# CLOCK - 200MHz differential system clock
# ================================================================
# Negative clock input
set_property -dict {PACKAGE_PIN AD11 IOSTANDARD LVDS} [get_ports i_sysclk_n]
# Positive clock input
set_property -dict {PACKAGE_PIN AD12 IOSTANDARD LVDS} [get_ports i_sysclk_p]
# 200MHz = 5ns period
create_clock -period 5 -name sysclk [get_ports i_sysclk_p]

# ================================================================
# UART - Serial communication for debug console
# ================================================================
# UART transmit
set_property -dict {PACKAGE_PIN Y23 IOSTANDARD LVCMOS33} [get_ports o_uart_tx]
# UART receive
set_property -dict {PACKAGE_PIN Y20 IOSTANDARD LVCMOS33} [get_ports i_uart_rx]

# ================================================================
# FAN CONTROL - PWM output for FPGA cooling fan
# ================================================================
# Fan PWM control
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports o_fan_pwm]

# ================================================================
# RESET - Push-button reset (active-low)
# ================================================================
# Reset button
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} [get_ports i_pb_resetn]

# The 200 MHz IBUFDS output drives both the board MMCM and (via its 200 MHz
# output) the MIG's internal MMCM/PLL: allow the backbone route between clock
# regions.
set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets differential_clock_200mhz_buffered]

# mem_ok crosses from the DDR controller's ui_clk (clk_pll_i) domain into the
# core-clock (clock_from_mmcm) reset tree through a dedicated 2FF synchronizer:
# cut the timing into it. Both clocks derive from the single 200 MHz i_sysclk_p
# but through separate MMCM/PLLs, so the crossing has no meaningful phase
# relationship and must not be timed.
# NOTE: the brackets are LITERAL in a `-filter {NAME =~ ...}` glob -- do NOT
# backslash-escape them. "reg\[0\]" matches a literal backslash and silently
# selects nothing, leaving the crossing timed (the synchronizer then shows up
# as the worst path, ~-0.5 ns, and poisons the build's WNS).
set_false_path -to [get_pins -hierarchical -filter {NAME =~ "*mem_ok_synchronizer_reg[0]/D"}]
