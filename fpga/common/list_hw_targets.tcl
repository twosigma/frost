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

# Print each hardware target on a line starting with TARGET:, which
# hw_target.py parses.

source [file join [file dirname [info script]] hw_session.tcl]
# Optional arguments: a remote host (port 3121), then a HOST:PORT server URL.
frost_hw_session [lindex $argv 0] [lindex $argv 1] "" {
    foreach target [get_hw_targets] {
        puts "TARGET:$target"
    }
}
