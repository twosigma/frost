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

# Program an FPGA bitstream over JTAG.

if { $argc < 3 } {
    puts "Error: Project root, board name, and hardware target required"
    puts "Usage: vivado -source program_bitstream.tcl -tclargs <project_root> <board_name> <hw_target> \[remote_host\] \[bitstream\] \[hw_server_url\]"
    exit 1
}
set project_root [lindex $argv 0]
set board_name [lindex $argv 1]
set hw_target [lindex $argv 2]
if {$hw_target eq ""} {
    puts stderr "Error: a nonempty exact hardware target is required"
    exit 1
}

set supported_boards [list x3]
if {[lsearch -exact $supported_boards $board_name] < 0} {
    puts "Error: Invalid board '$board_name'. Must be one of: [join $supported_boards {, }]"
    exit 1
}

# Validate before any cable access, including for direct Tcl callers.
set bitstream_file [lindex $argv 4]
if {$bitstream_file eq ""} {
    set bitstream_file ${project_root}/fpga/build/${board_name}/work/${board_name}_frost.bit
}
if {![file isfile $bitstream_file] || ![file readable $bitstream_file] ||
    [file size $bitstream_file] == 0 || [string tolower [file extension $bitstream_file]] ne ".bit"} {
    puts stderr "Error: bitstream must be an existing readable nonempty .bit file: $bitstream_file"
    exit 1
}

source [file join [file dirname [info script]] .. common hw_session.tcl]
frost_hw_session [lindex $argv 3] [lindex $argv 5] $hw_target {
    set device [lindex [get_hw_devices] 0]
    set_property PROGRAM.FILE $bitstream_file $device
    program_hw_devices $device
    puts "FROST_PROGRAM_COMPLETE"
    flush stdout
}
