# Xilinx Design Constraints (XDC) for Genesys2 board
# Pin assignments, I/O standards, and timing constraints for Kintex-7 FPGA

# ================================================================
# CLOCK - 200MHz differential system clock
# ================================================================
set_property -dict {PACKAGE_PIN AD11 IOSTANDARD LVDS} [get_ports i_sysclk_n]
set_property -dict {PACKAGE_PIN AD12 IOSTANDARD LVDS} [get_ports i_sysclk_p]
create_clock -period 5 -name sysclk [get_ports i_sysclk_p]

# ================================================================
# UART - Serial communication for debug console
# ================================================================
set_property -dict {PACKAGE_PIN Y23 IOSTANDARD LVCMOS33} [get_ports o_uart_tx]
set_property -dict {PACKAGE_PIN Y20 IOSTANDARD LVCMOS33} [get_ports i_uart_rx]

# ================================================================
# FAN CONTROL - active-high output for FPGA cooling fan
# ================================================================
# FAN_PWM high runs the fan continuously at full speed.
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports o_fan_pwm]

# ================================================================
# RESET - Push-button reset (active-low)
# ================================================================
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} [get_ports i_pb_resetn]

# The 200 MHz IBUFDS output drives the board MMCM, and the MMCM's 200 MHz
# output drives the MIG's internal MMCM/PLL. Allow the backbone route between
# clock regions.
set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets differential_clock_200mhz_buffered]

# mem_ok crosses from the DDR controller's ui_clk (clk_pll_i) domain into the
# core-clock (clock_from_mmcm) reset tree through a dedicated 2FF synchronizer.
# Cut the timing into it: both clocks derive from the single 200 MHz i_sysclk_p
# but through separate MMCM/PLLs, so the crossing has no meaningful phase
# relationship and must not be timed.
# Do not backslash-escape the brackets: they are literal in a
# `-filter {NAME =~ ...}` glob. "reg\[0\]" matches a literal backslash and
# silently selects nothing, leaving the crossing timed. The synchronizer then
# shows up as the worst path, ~-0.5 ns, and poisons the build's WNS.
set_false_path -to [get_pins -hierarchical -filter {NAME =~ "*mem_ok_synchronizer_reg[0]/D"}]
