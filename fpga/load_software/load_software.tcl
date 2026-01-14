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

# Vivado TCL script to load software into FPGA instruction memory via JTAG
# Writes compiled program into BRAM through AXI interface without reprogramming bitstream

if { $argc < 3 } {
    puts "Error: Project root, software application name, and hardware target required"
    puts "Usage: vivado -source load_software.tcl -tclargs <project_root> <app_name> <hw_target> \[remote_host\]"
    exit 1
}
set project_root [lindex $argv 0]
set software_application_name [lindex $argv 1]
set hw_target [lindex $argv 2]

# Valid software applications (alphabetically sorted)
set valid_apps [list c_ext_test call_stress coremark csr_test freertos_demo \
                     hello_world isa_test memory_test packet_parser \
                     print_clock_speed spanning_test strings_test uart_echo]

if { [lsearch -exact $valid_apps $software_application_name] == -1 } {
    puts "Error: Invalid software app '$software_application_name'"
    puts "Valid apps: [join $valid_apps {, }]"
    exit 1
}

# Path to software binary in Vivado BRAM format (8 hex digits per line)
set firmware_text_file ${project_root}/sw/apps/${software_application_name}/sw.txt

# Source helper function for writing binary data to BRAM via AXI
set script_dir [file dirname [file normalize [info script]]]
source ${script_dir}/file_to_bram.tcl

# Connect to FPGA hardware via JTAG
open_hw_manager
if { $argc >= 4 } {
    # Remote host was provided - connect to remote hardware server
    set remote_hardware_server [lindex $argv 3]
    connect_hw_server -url ${remote_hardware_server}:3121
} else {
    # No remote host - connect to local hardware server
    connect_hw_server
}

# Select the specified hardware target and open it
current_hw_target $hw_target
open_hw_target

# Refresh device and reset AXI interface
refresh_hw_device [lindex [get_hw_devices] 0]
reset_hw_axi [get_hw_axis -of_objects [lindex [get_hw_devices] 0]]

# Write software to instruction memory starting at address 0
set bram_base_address 0x00000000
file2bram $bram_base_address $firmware_text_file
