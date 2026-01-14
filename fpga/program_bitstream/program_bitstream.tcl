#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

# Vivado TCL script to program FPGA bitstream via JTAG
# Loads compiled bitstream into FPGA configuration memory

if { $argc < 3 } {
    puts "Error: Project root, board name, and hardware target required"
    puts "Usage: vivado -source program_bitstream.tcl -tclargs <project_root> <board_name> <hw_target> \[remote_host\]"
    exit 1
}
set project_root [lindex $argv 0]
set board_name [lindex $argv 1]
set hw_target [lindex $argv 2]

if { $board_name != "x3" && $board_name != "genesys2" && $board_name != "nexys_a7" } {
    puts "Error: Invalid board '$board_name'. Must be 'x3', 'genesys2', or 'nexys_a7'"
    exit 1
}

# Connect to FPGA hardware via JTAG
open_hw_manager
if { $argc >= 4 } {
    # Remote hardware server specified - connect to remote FPGA
    set remote_hardware_server [lindex $argv 3]
    connect_hw_server -url ${remote_hardware_server}:3121
} else {
    # No remote host - connect to local hardware server
    connect_hw_server
}

# Select the specified hardware target
current_hw_target $hw_target
open_hw_target

# Configure device with bitstream file path
set bitstream_file ${project_root}/fpga/build/${board_name}/work/${board_name}_frost.bit
set_property PROGRAM.FILE $bitstream_file [lindex [get_hw_devices] 0]

# Program the FPGA device with bitstream
program_hw_devices [lindex [get_hw_devices] 0]
