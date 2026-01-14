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

# Vivado TCL script to enumerate available hardware targets
# Outputs one target per line with "TARGET:" prefix for parsing

open_hw_manager

if { $argc >= 1 } {
    # Remote hardware server specified
    set remote_hardware_server [lindex $argv 0]
    connect_hw_server -url ${remote_hardware_server}:3121
} else {
    # Connect to local hardware server
    connect_hw_server
}

# List all available hardware targets
foreach target [get_hw_targets] {
    puts "TARGET:$target"
}

close_hw_server
